#!/usr/bin/env bash
# Shared Treehouse worktree lease protection for spawn and bootstrap.
#
# Public functions:
#   fm_treehouse_lease_acquire_noncolliding <state-dir> <project-dir> <holder>
#     Starts a verified cwd barrier in every local worktree recorded by task
#     metadata before running a bounded sequence of durable Treehouse lease
#     acquisitions. Every returned path is normalized and compared with every
#     worktree= value in <state-dir>/*.meta. The function redraws until it sets
#     FM_TREEHOUSE_LEASE_PATH to a non-colliding path or fails loudly after
#     exhausting the distinct recorded collision paths plus one safe draw.
#   fm_treehouse_lease_return_if_holder <project-dir> <path> <holder>
#     Releases one accepted lease during pre-publication spawn rollback, guarded
#     by Treehouse's holder check so cleanup cannot return another owner's lease.
#   fm_worktree_protection_sweep <state-dir>
#     Re-establishes protection for every local Treehouse worktree recorded in
#     task metadata. Quiescent worktrees receive a durable metadata exclusion;
#     occupied worktrees receive an identity-bound long-lived cwd guard. Records
#     live under state/.worktree-protection/.
#
# Callers must source fm-wake-lib.sh first for fm_pid_identity. The sweep prints
# WORKTREE_PROTECTION diagnostics only when a recorded Treehouse worktree cannot
# be inspected or protected; successful and non-Treehouse records stay silent.

# shellcheck source=bin/fm-session-lock-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-session-lock-lib.sh"

# shellcheck disable=SC2034 # Read by fm-spawn after acquisition returns.
FM_TREEHOUSE_LEASE_PATH=
FM_TREEHOUSE_COLLISION_OWNER=
FM_TREEHOUSE_COLLISION_ERROR=
FM_TREEHOUSE_COLLISION_PATH_COUNT=0
FM_TREEHOUSE_ACQUIRE_GUARDS=
FM_TREEHOUSE_ACQUIRE_PID=
FM_TREEHOUSE_ACQUIRE_IDENTITY=
FM_TREEHOUSE_ACQUIRE_OUTPUT=
FM_TREEHOUSE_ACQUIRE_START=
FM_TREEHOUSE_ACQUIRE_STATE=
FM_TREEHOUSE_ACQUIRE_PROJECT=
FM_TREEHOUSE_ACQUIRE_HOLDER=
FM_TREEHOUSE_PENDING_LEASE_PATH=
FM_WORKTREE_META_ERROR=
FM_WORKTREE_META_BACKEND=
FM_WORKTREE_META_REMOTE_HOST=
FM_WORKTREE_META_WORKTREE=
FM_WORKTREE_GUARD_PID=
FM_WORKTREE_GUARD_IDENTITY=
FM_WORKTREE_PROTECTION_ERROR=
FM_WORKTREE_PROTECTION_MODE=
FM_WORKTREE_PROTECTION_WORKTREE=
FM_WORKTREE_PROCESS_COMM=
FM_WORKTREE_PROCESS_ARGS=

fm_worktree_real_or_raw() {  # <path>
  local path=$1
  if [ -d "$path" ]; then
    (CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

fm_worktree_meta_read() {  # <meta>
  local meta=$1 content line worktree_count=0
  FM_WORKTREE_META_ERROR=
  FM_WORKTREE_META_BACKEND=
  FM_WORKTREE_META_REMOTE_HOST=
  FM_WORKTREE_META_WORKTREE=
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    FM_WORKTREE_META_ERROR="unsafe task metadata path: $meta"
    return 2
  fi
  if ! content=$(cat -- "$meta" 2>/dev/null); then
    FM_WORKTREE_META_ERROR="cannot read task metadata: $meta"
    return 2
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      backend=*) FM_WORKTREE_META_BACKEND=${line#backend=} ;;
      remote_host=*) FM_WORKTREE_META_REMOTE_HOST=${line#remote_host=} ;;
      worktree=*)
        worktree_count=$((worktree_count + 1))
        FM_WORKTREE_META_WORKTREE=${line#worktree=}
        ;;
    esac
  done <<< "$content"
  if [ "$worktree_count" -gt 1 ]; then
    FM_WORKTREE_META_ERROR="ambiguous worktree fields in task metadata: $meta"
    return 2
  fi
}

fm_worktree_treehouse_status_row() {
  local target=$1
  node -e '
    const fs = require("fs");
    const normalize = (value) => {
      if (typeof value !== "string") return null;
      try { return fs.realpathSync(value); } catch { return value; }
    };
    const target = normalize(process.argv[1]);
    let rows;
    try { rows = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    if (!Array.isArray(rows)) process.exit(2);
    const row = rows.find((candidate) =>
      candidate && normalize(candidate.path) === target);
    if (!row) process.exit(3);
    if (typeof row.lease_id === "string" && row.lease_id) {
      process.stdout.write("none");
      process.exit(0);
    }
    if (!Array.isArray(row.processes)) process.exit(2);
    for (const entry of row.processes) {
      if (!entry || !Number.isInteger(entry.pid)) process.exit(2);
    }
    process.stdout.write(["unleased", ...row.processes.map((entry) => entry.pid)].join("\n"));
  ' "$target"
}

fm_worktree_collision_owner() {  # <state-dir> <candidate>
  local state=$1 candidate=$2 candidate_real meta recorded recorded_real
  FM_TREEHOUSE_COLLISION_OWNER=
  FM_TREEHOUSE_COLLISION_ERROR=
  candidate_real=$(fm_worktree_real_or_raw "$candidate")
  [ -d "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! fm_worktree_meta_read "$meta"; then
      FM_TREEHOUSE_COLLISION_ERROR=$FM_WORKTREE_META_ERROR
      return 2
    fi
    recorded=$FM_WORKTREE_META_WORKTREE
    [ -n "$recorded" ] || continue
    recorded_real=$(fm_worktree_real_or_raw "$recorded")
    [ "$recorded_real" = "$candidate_real" ] || continue
    FM_TREEHOUSE_COLLISION_OWNER=$(basename "$meta" .meta)
    return 0
  done
  return 1
}

fm_worktree_collision_path_count() {  # <state-dir>
  local state=$1 meta recorded recorded_real paths=$'\n'
  FM_TREEHOUSE_COLLISION_PATH_COUNT=0
  FM_TREEHOUSE_COLLISION_ERROR=
  [ -d "$state" ] || return 0
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! fm_worktree_meta_read "$meta"; then
      FM_TREEHOUSE_COLLISION_ERROR=$FM_WORKTREE_META_ERROR
      return 2
    fi
    recorded=$FM_WORKTREE_META_WORKTREE
    [ -n "$recorded" ] || continue
    recorded_real=$(fm_worktree_real_or_raw "$recorded")
    case "$paths" in
      *$'\n'"$recorded_real"$'\n'*) continue ;;
    esac
    paths="${paths}${recorded_real}"$'\n'
    FM_TREEHOUSE_COLLISION_PATH_COUNT=$((FM_TREEHOUSE_COLLISION_PATH_COUNT + 1))
  done
}

fm_worktree_meta_local_path() {  # <meta> -> sets FM_WORKTREE_PROTECTION_WORKTREE
  local meta=$1 backend remote worktree
  FM_WORKTREE_PROTECTION_WORKTREE=
  if ! fm_worktree_meta_read "$meta"; then
    FM_WORKTREE_PROTECTION_ERROR=$FM_WORKTREE_META_ERROR
    return 2
  fi
  backend=$FM_WORKTREE_META_BACKEND
  [ "$backend" != orca ] || return 1
  remote=$FM_WORKTREE_META_REMOTE_HOST
  [ -z "$remote" ] || return 1
  worktree=$FM_WORKTREE_META_WORKTREE
  case "$worktree" in
    /*) ;;
    '') return 1 ;;
    *)
      FM_WORKTREE_PROTECTION_ERROR="recorded worktree is not absolute: $worktree"
      return 2
      ;;
  esac
  [ -d "$worktree" ] || {
    FM_WORKTREE_PROTECTION_WORKTREE=$worktree
    FM_WORKTREE_PROTECTION_ERROR="recorded worktree is unavailable: $worktree"
    return 2
  }
  FM_WORKTREE_PROTECTION_WORKTREE=$(fm_worktree_real_or_raw "$worktree")
}

fm_worktree_process_cwd() {  # <pid>
  local pid=$1 cwd
  if [ -L "/proc/$pid/cwd" ]; then
    readlink "/proc/$pid/cwd" 2>/dev/null
    return
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  cwd=$(lsof -a -p "$pid" -d cwd -Fn 2>/dev/null | sed -n 's/^n//p' | head -n 1)
  [ -n "$cwd" ] || return 1
  printf '%s\n' "$cwd"
}

fm_worktree_guard_process_start() {  # <worktree> <detached:0|1>
  local worktree=$1 detached=$2 pid identity previous_identity='' current_cwd stable=0 _
  FM_WORKTREE_GUARD_PID=
  FM_WORKTREE_GUARD_IDENTITY=
  if [ "$detached" = 1 ]; then
    # shellcheck disable=SC2016 # $1 is intentionally expanded by the child bash.
    nohup bash -c 'cd "$1" || exit 1; exec sleep 2147483647' \
      fm-worktree-presence "$worktree" </dev/null >/dev/null 2>&1 &
  else
    # shellcheck disable=SC2016 # $1 is intentionally expanded by the child bash.
    bash -c 'cd "$1" || exit 1; exec sleep 2147483647' \
      fm-worktree-acquire "$worktree" </dev/null >/dev/null 2>&1 &
  fi
  pid=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ -n "$identity" ] && [ "$identity" = "$previous_identity" ]; then
      current_cwd=$(fm_worktree_process_cwd "$pid" 2>/dev/null || true)
      if [ "$(fm_worktree_real_or_raw "$current_cwd")" = "$worktree" ]; then
        stable=1
        break
      fi
    fi
    previous_identity=$identity
    sleep 0.05
  done
  if [ "$stable" -ne 1 ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    return 1
  fi
  FM_WORKTREE_GUARD_PID=$pid
  FM_WORKTREE_GUARD_IDENTITY=$identity
}

fm_treehouse_acquire_barrier_stop() {
  local pid identity current_identity
  while IFS=$'\t' read -r pid identity; do
    [ -n "$pid" ] || continue
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ -n "$identity" ] && [ "$current_identity" = "$identity" ]; then
      kill "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  done <<< "$FM_TREEHOUSE_ACQUIRE_GUARDS"
  FM_TREEHOUSE_ACQUIRE_GUARDS=
}

fm_treehouse_active_acquire_stop() {
  local pid=$FM_TREEHOUSE_ACQUIRE_PID output=$FM_TREEHOUSE_ACQUIRE_OUTPUT
  local state=$FM_TREEHOUSE_ACQUIRE_STATE project=$FM_TREEHOUSE_ACQUIRE_PROJECT
  local holder=$FM_TREEHOUSE_ACQUIRE_HOLDER identity=$FM_TREEHOUSE_ACQUIRE_IDENTITY
  local start=$FM_TREEHOUSE_ACQUIRE_START candidate pending=0 collision_status
  local current_identity reconcile_status=1
  if [ -n "$pid" ] && [ -n "$identity" ]; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ "$current_identity" = "$identity" ]; then
      kill -TERM "$pid" 2>/dev/null || true
    fi
    sleep 0.1
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
    if [ "$current_identity" = "$identity" ]; then
      kill -KILL "$pid" 2>/dev/null || true
    fi
    wait "$pid" 2>/dev/null || true
  fi
  if [ -n "$FM_TREEHOUSE_PENDING_LEASE_PATH" ]; then
    candidate=$FM_TREEHOUSE_PENDING_LEASE_PATH
    pending=1
  elif [ -n "$output" ] && [ -f "$output" ]; then
    candidate=$(< "$output")
  fi
  if [ -z "$candidate" ] && [ -n "$project" ] && [ -n "$holder" ]; then
    if fm_treehouse_reconcile_holder_leases "$state" "$project" "$holder"; then
      reconcile_status=0
    else
      reconcile_status=$?
    fi
    if [ "$reconcile_status" -ne 0 ]; then
      echo "error: could not reconcile interrupted Treehouse lease holder '$holder'" >&2
    fi
  elif [ -n "$candidate" ] && [ -n "$project" ] && [ -n "$holder" ]; then
    case "$candidate" in
      /*$'\n'*|[!/]*|"") ;;
      /*)
        if [ "$pending" -eq 1 ]; then
          fm_treehouse_lease_return_if_holder \
            "$project" "$candidate" "$holder" >/dev/null 2>&1 || true
        elif fm_worktree_collision_owner "$state" "$candidate"; then
          :
        else
          collision_status=$?
          if [ "$collision_status" -eq 1 ]; then
            fm_treehouse_lease_return_if_holder \
              "$project" "$candidate" "$holder" >/dev/null 2>&1 || true
          fi
        fi
        ;;
    esac
  fi
  FM_TREEHOUSE_ACQUIRE_PID=
  FM_TREEHOUSE_ACQUIRE_IDENTITY=
  FM_TREEHOUSE_ACQUIRE_OUTPUT=
  FM_TREEHOUSE_ACQUIRE_START=
  FM_TREEHOUSE_ACQUIRE_STATE=
  FM_TREEHOUSE_ACQUIRE_PROJECT=
  FM_TREEHOUSE_ACQUIRE_HOLDER=
  FM_TREEHOUSE_PENDING_LEASE_PATH=
  [ -z "$output" ] || rm -f -- "$output"
  [ -z "$start" ] || rm -f -- "$start"
}

fm_treehouse_acquire_output_clear() {
  [ -z "$FM_TREEHOUSE_ACQUIRE_OUTPUT" ] \
    || rm -f -- "$FM_TREEHOUSE_ACQUIRE_OUTPUT"
  FM_TREEHOUSE_ACQUIRE_OUTPUT=
}

fm_treehouse_acquire_start_clear() {
  [ -z "$FM_TREEHOUSE_ACQUIRE_START" ] \
    || rm -f -- "$FM_TREEHOUSE_ACQUIRE_START"
  FM_TREEHOUSE_ACQUIRE_START=
}

fm_treehouse_acquire_context_clear() {
  FM_TREEHOUSE_ACQUIRE_PID=
  FM_TREEHOUSE_ACQUIRE_IDENTITY=
  fm_treehouse_acquire_output_clear
  fm_treehouse_acquire_start_clear
  FM_TREEHOUSE_ACQUIRE_STATE=
  FM_TREEHOUSE_ACQUIRE_PROJECT=
  FM_TREEHOUSE_ACQUIRE_HOLDER=
}

fm_treehouse_holder_lease_paths() {  # <holder>
  local holder=$1
  node -e '
    let rows;
    try { rows = JSON.parse(require("fs").readFileSync(0, "utf8")); }
    catch { process.exit(2); }
    if (!Array.isArray(rows)) process.exit(2);
    const holder = process.argv[1];
    for (const row of rows) {
      if (!row || row.lease_holder !== holder) continue;
      if (typeof row.lease_id !== "string" || !row.lease_id ||
          typeof row.path !== "string" || !row.path.startsWith("/") ||
          row.path.includes("\n")) process.exit(2);
      process.stdout.write(`${row.path}\n`);
    }
  ' "$holder"
}

fm_treehouse_reconcile_holder_leases() {  # <state-dir> <project-dir> <holder>
  local state=$1 project=$2 holder=$3 status_json paths path collision_status
  status_json=$(CDPATH='' cd -- "$project" && treehouse status --json) || return 1
  paths=$(printf '%s\n' "$status_json" | fm_treehouse_holder_lease_paths "$holder") \
    || return 1
  while IFS= read -r path; do
    [ -n "$path" ] || continue
    if fm_worktree_collision_owner "$state" "$path"; then
      continue
    else
      collision_status=$?
    fi
    [ "$collision_status" -eq 1 ] || return 1
    fm_treehouse_lease_return_if_holder "$project" "$path" "$holder" \
      >/dev/null 2>&1 || return 1
  done <<< "$paths"
}

fm_treehouse_lease_transfer() {  # <project-dir> <path> <holder>
  local project=$1 path=$2 holder=$3
  [ "$FM_TREEHOUSE_PENDING_LEASE_PATH" = "$path" ] \
    && [ "$FM_TREEHOUSE_ACQUIRE_PROJECT" = "$project" ] \
    && [ "$FM_TREEHOUSE_ACQUIRE_HOLDER" = "$holder" ] || return 1
  FM_TREEHOUSE_PENDING_LEASE_PATH=
  fm_treehouse_acquire_context_clear
}

fm_treehouse_acquire_signal_exit() {
  local status=$1
  fm_treehouse_active_acquire_stop
  fm_treehouse_acquire_barrier_stop
  exit "$status"
}

fm_treehouse_acquire_barrier_start() {  # <state-dir>
  local state=$1 meta status worktree protection_dir record mode guarded_paths=$'\n'
  FM_TREEHOUSE_ACQUIRE_GUARDS=
  [ -d "$state" ] || return 0
  protection_dir="$state/.worktree-protection"
  if [ -d "$protection_dir" ] && [ ! -L "$protection_dir" ]; then
    for record in "$protection_dir"/*.protection; do
      [ -f "$record" ] && [ ! -L "$record" ] || continue
      mode=$(fm_worktree_protection_record_value "$record" mode)
      worktree=$(fm_worktree_protection_record_value "$record" worktree)
      [ -d "$worktree" ] || continue
      worktree=$(fm_worktree_real_or_raw "$worktree")
      case "$mode" in
        presence)
          fm_worktree_protection_record_matches "$record" presence "$worktree" || continue
          ;;
        durable)
          fm_worktree_protection_record_matches "$record" durable "$worktree" || continue
          if ! fm_worktree_guard_process_start "$worktree" 0; then
            fm_treehouse_acquire_barrier_stop
            echo "error: cannot activate durable pre-acquisition exclusion for $worktree" >&2
            return 1
          fi
          FM_TREEHOUSE_ACQUIRE_GUARDS="${FM_TREEHOUSE_ACQUIRE_GUARDS}${FM_TREEHOUSE_ACQUIRE_GUARDS:+$'\n'}${FM_WORKTREE_GUARD_PID}"$'\t'"${FM_WORKTREE_GUARD_IDENTITY}"
          ;;
        *) continue ;;
      esac
      guarded_paths="${guarded_paths}${worktree}"$'\n'
    done
  fi
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    FM_WORKTREE_PROTECTION_ERROR=
    if fm_worktree_meta_local_path "$meta"; then
      status=0
      worktree=$FM_WORKTREE_PROTECTION_WORKTREE
    else
      status=$?
      worktree=
    fi
    case "$status" in
      0) ;;
      1) continue ;;
      *)
        fm_treehouse_acquire_barrier_stop
        echo "error: cannot establish pre-acquisition worktree exclusion: $FM_WORKTREE_PROTECTION_ERROR" >&2
        return 1
        ;;
    esac
    case "$guarded_paths" in
      *$'\n'"$worktree"$'\n'*) continue ;;
    esac
    if ! fm_worktree_guard_process_start "$worktree" 0; then
      fm_treehouse_acquire_barrier_stop
      echo "error: cannot establish pre-acquisition worktree exclusion for $worktree" >&2
      return 1
    fi
    FM_TREEHOUSE_ACQUIRE_GUARDS="${FM_TREEHOUSE_ACQUIRE_GUARDS}${FM_TREEHOUSE_ACQUIRE_GUARDS:+$'\n'}${FM_WORKTREE_GUARD_PID}"$'\t'"${FM_WORKTREE_GUARD_IDENTITY}"
    guarded_paths="${guarded_paths}${worktree}"$'\n'
  done
}

fm_treehouse_lease_acquire_noncolliding() {  # <state-dir> <project-dir> <holder>
  local state=$1 project=$2 holder=$3 attempts attempt=0 candidate candidate_real
  local rejected=0 rejected_paths=$'\n' collision_status acquire_status identity previous_identity _
  FM_TREEHOUSE_LEASE_PATH=
  [ -z "$FM_TREEHOUSE_PENDING_LEASE_PATH" ] || {
    echo "error: a prior Treehouse lease is still awaiting ownership transfer" >&2
    return 1
  }
  if ! fm_worktree_collision_path_count "$state"; then
    echo "error: cannot derive the durable Treehouse redraw bound from task metadata: $FM_TREEHOUSE_COLLISION_ERROR" >&2
    return 1
  fi
  FM_TREEHOUSE_ACQUIRE_STATE=$state
  FM_TREEHOUSE_ACQUIRE_PROJECT=$project
  FM_TREEHOUSE_ACQUIRE_HOLDER=$holder
  attempts=$((FM_TREEHOUSE_COLLISION_PATH_COUNT + 1))
  fm_treehouse_acquire_barrier_start "$state" || {
    fm_treehouse_acquire_context_clear
    return 1
  }
  while [ "$attempt" -lt "$attempts" ]; do
    attempt=$((attempt + 1))
    FM_TREEHOUSE_ACQUIRE_OUTPUT=$(mktemp "$state/.treehouse-acquire.XXXXXX") || {
      fm_treehouse_acquire_barrier_stop
      fm_treehouse_acquire_context_clear
      echo "error: could not create Treehouse acquisition output under $state" >&2
      return 1
    }
    FM_TREEHOUSE_ACQUIRE_START=$(mktemp "$state/.treehouse-acquire-start.XXXXXX") || {
      fm_treehouse_acquire_barrier_stop
      fm_treehouse_acquire_context_clear
      echo "error: could not create Treehouse acquisition start gate under $state" >&2
      return 1
    }
    rm -f -- "$FM_TREEHOUSE_ACQUIRE_START"
    (
      treehouse_pid=
      treehouse_identity=
      fm_treehouse_child_stop() {
        current_identity=$(fm_pid_identity "$treehouse_pid" 2>/dev/null || true)
        if [ -n "$current_identity" ]; then
          [ -n "$treehouse_identity" ] || treehouse_identity=$current_identity
          if [ "$current_identity" = "$treehouse_identity" ]; then
            kill -TERM "$treehouse_pid" 2>/dev/null || true
          fi
        fi
        sleep 0.1
        current_identity=$(fm_pid_identity "$treehouse_pid" 2>/dev/null || true)
        if [ -n "$treehouse_identity" ] \
          && [ "$current_identity" = "$treehouse_identity" ]; then
          kill -KILL "$treehouse_pid" 2>/dev/null || true
        fi
        wait "$treehouse_pid" 2>/dev/null || true
      }
      trap 'fm_treehouse_child_stop; exit 130' INT
      trap 'fm_treehouse_child_stop; exit 143' TERM
      while [ ! -e "$FM_TREEHOUSE_ACQUIRE_START" ]; do sleep 0.01; done
      rm -f -- "$FM_TREEHOUSE_ACQUIRE_START"
      CDPATH='' cd -- "$project" || exit 1
      treehouse get --lease --lease-holder "$holder" &
      treehouse_pid=$!
      previous_identity=
      for _ in 1 2 3 4 5 6 7 8 9 10; do
        treehouse_identity=$(fm_pid_identity "$treehouse_pid" 2>/dev/null || true)
        if [ -n "$treehouse_identity" ] \
          && [ "$treehouse_identity" = "$previous_identity" ]; then
          break
        fi
        previous_identity=$treehouse_identity
        sleep 0.01
      done
      if wait "$treehouse_pid"; then
        treehouse_status=0
      else
        treehouse_status=$?
      fi
      exit "$treehouse_status"
    ) > "$FM_TREEHOUSE_ACQUIRE_OUTPUT" &
    FM_TREEHOUSE_ACQUIRE_PID=$!
    previous_identity=
    identity=
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      identity=$(fm_pid_identity "$FM_TREEHOUSE_ACQUIRE_PID" 2>/dev/null || true)
      if [ -n "$identity" ] && [ "$identity" = "$previous_identity" ]; then
        break
      fi
      previous_identity=$identity
      sleep 0.01
    done
    if [ -z "$identity" ] || [ "$identity" != "$previous_identity" ]; then
      kill "$FM_TREEHOUSE_ACQUIRE_PID" 2>/dev/null || true
      wait "$FM_TREEHOUSE_ACQUIRE_PID" 2>/dev/null || true
      fm_treehouse_acquire_barrier_stop
      fm_treehouse_acquire_context_clear
      echo "error: could not capture stable Treehouse acquisition process identity" >&2
      return 1
    fi
    FM_TREEHOUSE_ACQUIRE_IDENTITY=$identity
    : > "$FM_TREEHOUSE_ACQUIRE_START"
    if wait "$FM_TREEHOUSE_ACQUIRE_PID"; then
      acquire_status=0
    else
      acquire_status=$?
    fi
    FM_TREEHOUSE_ACQUIRE_PID=
    FM_TREEHOUSE_ACQUIRE_IDENTITY=
    fm_treehouse_acquire_start_clear
    candidate=$(< "$FM_TREEHOUSE_ACQUIRE_OUTPUT")
    if [ "$acquire_status" -ne 0 ]; then
      fm_treehouse_acquire_output_clear
      fm_treehouse_acquire_barrier_stop
      fm_treehouse_acquire_context_clear
      if [ "$rejected" -gt 0 ]; then
        echo "error: treehouse durable lease attempt $attempt failed after rejecting $rejected recorded live task worktree collision(s); could not produce a non-colliding worktree within $attempts attempts" >&2
      else
        echo "error: treehouse get --lease failed to acquire a worktree for $holder" >&2
      fi
      return 1
    fi
    case "$candidate" in
      /*$'\n'*|''|[!/]*)
        [ -z "$candidate" ] || fm_treehouse_lease_return_if_holder \
          "$project" "$candidate" "$holder" >/dev/null 2>&1 || true
        fm_treehouse_acquire_output_clear
        fm_treehouse_acquire_barrier_stop
        fm_treehouse_acquire_context_clear
        echo "error: treehouse get --lease returned a non-absolute worktree path: '${candidate:-empty}'" >&2
        return 1
        ;;
      /*) ;;
    esac
    if fm_worktree_collision_owner "$state" "$candidate"; then
      candidate_real=$(fm_worktree_real_or_raw "$candidate")
      case "$rejected_paths" in
        *$'\n'"$candidate_real"$'\n'*)
          fm_treehouse_acquire_output_clear
          fm_treehouse_acquire_barrier_stop
          fm_treehouse_acquire_context_clear
          echo "error: treehouse repeated recorded live task worktree '$candidate' after rejecting $rejected distinct collision(s); refusing further redraws after $attempt of $attempts bounded attempts" >&2
          return 1
          ;;
      esac
      rejected_paths="${rejected_paths}${candidate_real}"$'\n'
      rejected=$((rejected + 1))
      echo "warning: treehouse returned pre-excluded recorded live task worktree '$candidate' owned by $FM_TREEHOUSE_COLLISION_OWNER; preserving that durable lease and redrawing ($attempt/$attempts)" >&2
      fm_treehouse_acquire_output_clear
      continue
    else
      collision_status=$?
      if [ "$collision_status" -eq 2 ]; then
        fm_treehouse_lease_return_if_holder "$project" "$candidate" "$holder" >/dev/null 2>&1 || true
        fm_treehouse_acquire_output_clear
        fm_treehouse_acquire_barrier_stop
        fm_treehouse_acquire_context_clear
        echo "error: cannot verify durable Treehouse lease '$candidate' against task metadata: $FM_TREEHOUSE_COLLISION_ERROR" >&2
        return 1
      fi
    fi
    FM_TREEHOUSE_PENDING_LEASE_PATH=$candidate
    fm_treehouse_acquire_output_clear
    # shellcheck disable=SC2034 # Read by fm-spawn after this function returns.
    FM_TREEHOUSE_LEASE_PATH=$candidate
    fm_treehouse_acquire_barrier_stop
    return 0
  done
  fm_treehouse_acquire_barrier_stop
  fm_treehouse_acquire_context_clear
  echo "error: treehouse could not produce a non-colliding worktree after $attempts durable lease attempts; every lease matched a recorded live task worktree in $state" >&2
  return 1
}

fm_treehouse_lease_return_if_holder() {  # <project-dir> <path> <holder>
  local project=$1 path=$2 holder=$3
  (CDPATH='' cd -- "$project" \
    && treehouse return --force --if-lease-holder "$holder" "$path")
}

fm_worktree_protection_record_value() {  # <record> <key>
  local record=$1 key=$2
  sed -n "s/^${key}=//p" "$record" 2>/dev/null | tail -n 1
}

fm_worktree_protection_record_matches() {  # <record> <mode> <worktree>
  local record=$1 mode=$2 worktree=$3 recorded_mode recorded_worktree pid recorded_identity current_identity current_cwd
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  recorded_mode=$(fm_worktree_protection_record_value "$record" mode)
  [ "$recorded_mode" = "$mode" ] || return 1
  recorded_worktree=$(fm_worktree_protection_record_value "$record" worktree)
  [ "$recorded_worktree" = "$worktree" ] || return 1
  [ "$mode" = presence ] || return 0
  pid=$(fm_worktree_protection_record_value "$record" pid)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  recorded_identity=$(fm_worktree_protection_record_value "$record" pid_identity)
  [ -n "$recorded_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current_identity" = "$recorded_identity" ] || return 1
  current_cwd=$(fm_worktree_process_cwd "$pid") || return 1
  [ "$(fm_worktree_real_or_raw "$current_cwd")" = "$worktree" ]
}

fm_worktree_protection_record_stop() {  # <record>
  local record=$1 pid recorded_identity current_identity
  [ -f "$record" ] && [ ! -L "$record" ] || {
    rm -f -- "$record" 2>/dev/null || true
    return 0
  }
  pid=$(fm_worktree_protection_record_value "$record" pid)
  recorded_identity=$(fm_worktree_protection_record_value "$record" pid_identity)
  case "$pid" in
    ''|*[!0-9]*) ;;
    *)
      current_identity=$(fm_pid_identity "$pid" 2>/dev/null || true)
      if [ -n "$recorded_identity" ] && [ "$current_identity" = "$recorded_identity" ]; then
        kill "$pid" 2>/dev/null || true
      fi
      ;;
  esac
  rm -f -- "$record" 2>/dev/null || true
}

fm_worktree_presence_register() {  # <record> <worktree>
  local record=$1 worktree=$2 tmp
  fm_worktree_guard_process_start "$worktree" 1 || return 1
  tmp="$record.tmp.${BASHPID:-$$}"
  if ! {
    printf 'mode=presence\n'
    printf 'pid=%s\n' "$FM_WORKTREE_GUARD_PID"
    printf 'pid_identity=%s\n' "$FM_WORKTREE_GUARD_IDENTITY"
    printf 'worktree=%s\n' "$worktree"
  } > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp"
    kill "$FM_WORKTREE_GUARD_PID" 2>/dev/null || true
    return 1
  fi
}

fm_worktree_durable_exclusion_register() {  # <record> <worktree>
  local record=$1 worktree=$2 tmp
  tmp="$record.tmp.${BASHPID:-$$}"
  if ! {
    printf 'mode=durable\n'
    printf 'worktree=%s\n' "$worktree"
  } > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fm_worktree_process_snapshot() {  # <pid>
  local pid=$1 comm args
  FM_WORKTREE_PROCESS_COMM=
  FM_WORKTREE_PROCESS_ARGS=
  comm=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null) || return 1
  args=$(LC_ALL=C ps -p "$pid" -o args= 2>/dev/null) || return 1
  comm=${comm#"${comm%%[![:space:]]*}"}
  args=${args#"${args%%[![:space:]]*}"}
  [ -n "$comm" ] || return 1
  FM_WORKTREE_PROCESS_COMM=$comm
  FM_WORKTREE_PROCESS_ARGS=$args
}

fm_worktree_process_is_shell() {  # <comm>
  local comm=$1 base
  base=${comm##*/}
  base=${base#-}
  case "$base" in
    bash|zsh|sh|dash|ash|ksh|mksh|tcsh|csh|fish) return 0 ;;
  esac
  return 1
}

fm_worktree_shell_process_is_idle() {  # <args>
  local args=$1 index token
  local words=()
  read -r -a words <<< "$args"
  [ "${#words[@]}" -gt 0 ] || return 1
  for ((index=1; index<${#words[@]}; index++)); do
    token=${words[$index]}
    case "$token" in
      -l|--login|--noprofile|--norc|--noediting) ;;
      *) return 1 ;;
    esac
  done
}

fm_worktree_process_matches_harness() {  # <comm> <args> <harness>
  local comm=$1 args=$2 harness=$3 base argv0 argv0_base name
  base=${comm##*/}
  base=${base#-}
  argv0=${args%%[[:space:]]*}
  argv0_base=${argv0##*/}
  argv0_base=${argv0_base#-}
  if [ "$harness" = cursor ]; then
    fm_cursor_process_matches "$comm" "$args" "$argv0"
    return
  fi
  case "$harness:$base:$argv0_base" in
    muse:muse:*|muse:muse-bin-*:*|muse:*:muse|muse:*:muse-bin-*) return 0 ;;
    pi:pi:*|pi:Pi:*|pi:pi-signed:*|pi:pi-launcher:*|\
    pi:*:pi|pi:*:Pi|pi:*:pi-signed|pi:*:pi-launcher|\
    pi-signed:pi:*|pi-signed:Pi:*|pi-signed:pi-signed:*|pi-signed:pi-launcher:*|\
    pi-signed:*:pi|pi-signed:*:Pi|pi-signed:*:pi-signed|pi-signed:*:pi-launcher) return 0 ;;
  esac
  if [ "$base" = "$harness" ] || [ "$argv0_base" = "$harness" ]; then
    return 0
  fi
  fm_harness_process_matches "$comm" "$args" || return 1
  case "$harness:$base" in
    claude:*claude*|codex:*codex*|opencode:*opencode*|grok:*grok*|kimi:*kimi*) return 0 ;;
    pi:pi|pi:Pi|pi:pi-signed|pi:pi-launcher|pi-signed:pi|pi-signed:Pi|pi-signed:pi-signed|pi-signed:pi-launcher) return 0 ;;
  esac
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    [ "$name" = "$harness" ] && return 0
    case "$harness:$name" in pi:pi-signed|pi-signed:pi) return 0 ;; esac
  fi
  case "$comm" in
    *node*|*python*)
      case "$args" in *"$harness"*) return 0 ;; esac
      ;;
  esac
  return 1
}

fm_worktree_structural_protection_mode() {  # <meta> <process-pids> <protection-dir>
  local meta=$1 process_pids=$2 protection_dir=$3 harness record guard_pid pid
  local ignored_pids=$'\n' agent_found=0 uncertain_pid= cwd
  harness=$(fm_meta_get "$meta" harness)
  [ -n "$harness" ] || {
    FM_WORKTREE_PROTECTION_ERROR="recorded worktree has no harness identity: $FM_WORKTREE_PROTECTION_WORKTREE"
    return 2
  }
  if [ -d "$protection_dir" ] && [ ! -L "$protection_dir" ]; then
    for record in "$protection_dir"/*.protection; do
      [ -f "$record" ] && [ ! -L "$record" ] || continue
      fm_worktree_protection_record_matches \
        "$record" presence "$FM_WORKTREE_PROTECTION_WORKTREE" || continue
      guard_pid=$(fm_worktree_protection_record_value "$record" pid)
      ignored_pids="${ignored_pids}${guard_pid}"$'\n'
    done
  fi
  while IFS= read -r pid; do
    case "$pid" in ''|*[!0-9]*) continue ;; esac
    case "$ignored_pids" in *$'\n'"$pid"$'\n'*) continue ;; esac
    fm_worktree_process_snapshot "$pid" || continue
    cwd=$(fm_worktree_process_cwd "$pid" 2>/dev/null) || continue
    cwd=$(fm_worktree_real_or_raw "$cwd")
    case "$cwd" in
      "$FM_WORKTREE_PROTECTION_WORKTREE"|"$FM_WORKTREE_PROTECTION_WORKTREE"/*) ;;
      *) continue ;;
    esac
    if fm_worktree_process_is_shell "$FM_WORKTREE_PROCESS_COMM"; then
      if fm_worktree_process_is_shell "$harness" \
         && ! fm_worktree_shell_process_is_idle "$FM_WORKTREE_PROCESS_ARGS"; then
        uncertain_pid=$pid
      fi
      continue
    fi
    if fm_worktree_process_matches_harness \
      "$FM_WORKTREE_PROCESS_COMM" "$FM_WORKTREE_PROCESS_ARGS" "$harness"; then
      agent_found=1
      continue
    fi
    uncertain_pid=$pid
  done <<< "$process_pids"
  if [ "$agent_found" -eq 1 ]; then
    FM_WORKTREE_PROTECTION_MODE=presence
    return 0
  fi
  if [ -n "$uncertain_pid" ]; then
    FM_WORKTREE_PROTECTION_ERROR="cannot attribute worktree process $uncertain_pid to recorded harness $harness: $FM_WORKTREE_PROTECTION_WORKTREE"
    return 2
  fi
  FM_WORKTREE_PROTECTION_MODE=durable
}

fm_worktree_meta_protection_mode() {  # <meta> <protection-dir> -> sets mode and worktree globals
  local meta=$1 protection_dir=$2 pool_status result membership process_pids status backend target agent_state
  local inspection_root membership_status
  FM_WORKTREE_PROTECTION_MODE=
  fm_worktree_meta_local_path "$meta" || return $?
  inspection_root=$(git -C "$FM_WORKTREE_PROTECTION_WORKTREE" worktree list --porcelain 2>/dev/null \
    | sed -n 's/^worktree //p' | head -n 1)
  if [ -n "$inspection_root" ] && [ -d "$inspection_root" ]; then
    inspection_root=$(fm_worktree_real_or_raw "$inspection_root")
  fi
  if [ -z "$inspection_root" ] || [ "$inspection_root" = "$FM_WORKTREE_PROTECTION_WORKTREE" ]; then
    if ! membership_status=$(CDPATH='' cd -- "$FM_WORKTREE_PROTECTION_WORKTREE" \
      && treehouse status --json 2>/dev/null); then
      FM_WORKTREE_PROTECTION_ERROR="treehouse status failed for recorded worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
      return 2
    fi
    if printf '%s\n' "$membership_status" \
      | fm_worktree_treehouse_status_row "$FM_WORKTREE_PROTECTION_WORKTREE" \
        >/dev/null 2>&1; then
      status=0
    else
      status=$?
    fi
    case "$status" in
      3) return 1 ;;
      0)
        FM_WORKTREE_PROTECTION_ERROR="could not resolve an inspection root outside recorded Treehouse worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
        return 2
        ;;
      *)
        FM_WORKTREE_PROTECTION_ERROR="treehouse status returned invalid JSON for recorded worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
        return 2
        ;;
    esac
  fi
  if ! pool_status=$(CDPATH='' cd -- "$inspection_root" \
    && treehouse status --json 2>/dev/null); then
    FM_WORKTREE_PROTECTION_ERROR="treehouse status failed for recorded worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
    return 2
  fi
  result=$(printf '%s\n' "$pool_status" \
    | fm_worktree_treehouse_status_row "$FM_WORKTREE_PROTECTION_WORKTREE" 2>/dev/null)
  status=$?
  case "$status" in
    0) ;;
    3) return 1 ;;
    *)
      FM_WORKTREE_PROTECTION_ERROR="treehouse status returned invalid JSON for recorded worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
      return 2
      ;;
  esac
  membership=${result%%$'\n'*}
  if [ "$membership" = none ]; then
    FM_WORKTREE_PROTECTION_MODE=none
    return 0
  fi
  process_pids=
  case "$result" in *$'\n'*) process_pids=${result#*$'\n'} ;; esac
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  agent_state=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null) \
    || agent_state=unreadable
  case "$backend:$agent_state" in
    *:alive) FM_WORKTREE_PROTECTION_MODE=presence ;;
    *:dead|*:missing) FM_WORKTREE_PROTECTION_MODE=durable ;;
    zellij:unverified|cmux:unverified)
      fm_worktree_structural_protection_mode "$meta" "$process_pids" "$protection_dir"
      ;;
    *)
      FM_WORKTREE_PROTECTION_ERROR="backend $backend could not determine agent occupancy ($agent_state): $FM_WORKTREE_PROTECTION_WORKTREE"
      return 2
      ;;
  esac
}

fm_worktree_protection_sweep() {  # <state-dir>
  local state=$1 protection_dir record meta id worktree mode status recorded_worktree
  FM_WORKTREE_PROTECTION_ERROR=
  [ -d "$state" ] || return 0
  protection_dir="$state/.worktree-protection"
  if [ -L "$protection_dir" ] || { [ -e "$protection_dir" ] && [ ! -d "$protection_dir" ]; }; then
    echo "WORKTREE_PROTECTION: failed: unsafe protection directory path: $protection_dir"
    return 1
  fi
  mkdir -p "$protection_dir" || {
    echo "WORKTREE_PROTECTION: failed: could not create $protection_dir"
    return 1
  }
  chmod 700 "$protection_dir" 2>/dev/null || true

  for record in "$protection_dir"/*.protection; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    id=$(basename "$record" .protection)
    meta="$state/$id.meta"
    worktree=
    mode=
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      FM_WORKTREE_PROTECTION_ERROR=
      if fm_worktree_meta_protection_mode "$meta" "$protection_dir" 2>/dev/null; then
        status=0
      else
        status=$?
      fi
      case "$status" in
        0)
          worktree=$FM_WORKTREE_PROTECTION_WORKTREE
          mode=$FM_WORKTREE_PROTECTION_MODE
          ;;
        1) ;;
        *)
          recorded_worktree=$(fm_worktree_protection_record_value "$record" worktree)
          if [ -n "$FM_WORKTREE_PROTECTION_WORKTREE" ] \
             && [ "$recorded_worktree" = "$FM_WORKTREE_PROTECTION_WORKTREE" ]; then
            continue
          fi
          ;;
      esac
    fi
    if [ "$mode" = none ] || [ -z "$mode" ] \
       || ! fm_worktree_protection_record_matches "$record" "$mode" "$worktree"; then
      fm_worktree_protection_record_stop "$record"
    fi
  done

  for meta in "$state"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=$(basename "$meta" .meta)
    case "$id" in
      ''|*[!A-Za-z0-9._-]*)
        echo "WORKTREE_PROTECTION: task ${id:-unknown}: skipped: unsafe metadata filename"
        continue
        ;;
    esac
    FM_WORKTREE_PROTECTION_ERROR=
    if fm_worktree_meta_protection_mode "$meta" "$protection_dir"; then
      status=0
      worktree=$FM_WORKTREE_PROTECTION_WORKTREE
      mode=$FM_WORKTREE_PROTECTION_MODE
    else
      status=$?
      worktree=
      mode=
    fi
    case "$status" in
      0) ;;
      1) continue ;;
      *)
        echo "WORKTREE_PROTECTION: task $id: skipped: $FM_WORKTREE_PROTECTION_ERROR"
        continue
        ;;
    esac
    [ "$mode" != none ] || continue
    record="$protection_dir/$id.protection"
    fm_worktree_protection_record_matches "$record" "$mode" "$worktree" && continue
    fm_worktree_protection_record_stop "$record"
    case "$mode" in
      durable)
        if ! fm_worktree_durable_exclusion_register "$record" "$worktree"; then
          echo "WORKTREE_PROTECTION: task $id: failed: could not register a durable exclusion for $worktree"
        fi
        ;;
      presence)
        if ! fm_worktree_presence_register "$record" "$worktree"; then
          echo "WORKTREE_PROTECTION: task $id: failed: could not start a presence guard for $worktree"
        fi
        ;;
    esac
  done
}
