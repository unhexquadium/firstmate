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
#     eight attempts.
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

# shellcheck disable=SC2034 # Read by fm-spawn after acquisition returns.
FM_TREEHOUSE_LEASE_PATH=
FM_TREEHOUSE_COLLISION_OWNER=
FM_TREEHOUSE_COLLISION_ERROR=
FM_TREEHOUSE_ACQUIRE_GUARDS=
FM_WORKTREE_GUARD_PID=
FM_WORKTREE_GUARD_IDENTITY=
FM_WORKTREE_PROTECTION_ERROR=
FM_WORKTREE_PROTECTION_MODE=
FM_WORKTREE_PROTECTION_WORKTREE=

fm_worktree_real_or_raw() {  # <path>
  local path=$1
  if [ -d "$path" ]; then
    (CDPATH='' cd -- "$path" 2>/dev/null && pwd -P) || printf '%s\n' "$path"
  else
    printf '%s\n' "$path"
  fi
}

fm_worktree_collision_owner() {  # <state-dir> <candidate>
  local state=$1 candidate=$2 candidate_real meta recorded recorded_real count
  FM_TREEHOUSE_COLLISION_OWNER=
  FM_TREEHOUSE_COLLISION_ERROR=
  candidate_real=$(fm_worktree_real_or_raw "$candidate")
  [ -d "$state" ] || return 1
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ ! -f "$meta" ] || [ -L "$meta" ]; then
      FM_TREEHOUSE_COLLISION_ERROR="unsafe task metadata path: $meta"
      return 2
    fi
    count=$(grep -c '^worktree=' "$meta" 2>/dev/null || true)
    if [ "$count" -gt 1 ]; then
      FM_TREEHOUSE_COLLISION_ERROR="ambiguous worktree fields in task metadata: $meta"
      return 2
    fi
    recorded=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | tail -n 1)
    [ -n "$recorded" ] || continue
    recorded_real=$(fm_worktree_real_or_raw "$recorded")
    [ "$recorded_real" = "$candidate_real" ] || continue
    FM_TREEHOUSE_COLLISION_OWNER=$(basename "$meta" .meta)
    return 0
  done
  return 1
}

fm_worktree_meta_local_path() {  # <meta> -> sets FM_WORKTREE_PROTECTION_WORKTREE
  local meta=$1 backend remote worktree count
  FM_WORKTREE_PROTECTION_WORKTREE=
  if [ ! -f "$meta" ] || [ -L "$meta" ]; then
    FM_WORKTREE_PROTECTION_ERROR="unsafe task metadata path: $meta"
    return 2
  fi
  backend=$(sed -n 's/^backend=//p' "$meta" 2>/dev/null | tail -n 1)
  [ "$backend" != orca ] || return 1
  remote=$(sed -n 's/^remote_host=//p' "$meta" 2>/dev/null | tail -n 1)
  [ -z "$remote" ] || return 1
  count=$(grep -c '^worktree=' "$meta" 2>/dev/null || true)
  if [ "$count" -gt 1 ]; then
    FM_WORKTREE_PROTECTION_ERROR="ambiguous worktree fields in task metadata: $meta"
    return 2
  fi
  worktree=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | tail -n 1)
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
  local state=$1 project=$2 holder=$3 attempts=8 attempt=0 candidate rejected=0 collision_status
  FM_TREEHOUSE_LEASE_PATH=
  fm_treehouse_acquire_barrier_start "$state" || return 1
  while [ "$attempt" -lt "$attempts" ]; do
    attempt=$((attempt + 1))
    if ! candidate=$(CDPATH='' cd -- "$project" \
      && treehouse get --lease --lease-holder "$holder"); then
      fm_treehouse_acquire_barrier_stop
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
        fm_treehouse_acquire_barrier_stop
        echo "error: treehouse get --lease returned a non-absolute worktree path: '${candidate:-empty}'" >&2
        return 1
        ;;
      /*) ;;
    esac
    if fm_worktree_collision_owner "$state" "$candidate"; then
      rejected=$((rejected + 1))
      echo "warning: treehouse returned pre-excluded recorded live task worktree '$candidate' owned by $FM_TREEHOUSE_COLLISION_OWNER; preserving that durable lease and redrawing ($attempt/$attempts)" >&2
      continue
    else
      collision_status=$?
      if [ "$collision_status" -eq 2 ]; then
        fm_treehouse_lease_return_if_holder "$project" "$candidate" "$holder" >/dev/null 2>&1 || true
        fm_treehouse_acquire_barrier_stop
        echo "error: cannot verify durable Treehouse lease '$candidate' against task metadata: $FM_TREEHOUSE_COLLISION_ERROR" >&2
        return 1
      fi
    fi
    # shellcheck disable=SC2034 # Read by fm-spawn after this function returns.
    FM_TREEHOUSE_LEASE_PATH=$candidate
    fm_treehouse_acquire_barrier_stop
    return 0
  done
  fm_treehouse_acquire_barrier_stop
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

fm_worktree_meta_protection_mode() {  # <meta> <protection-dir> -> sets mode and worktree globals
  local meta=$1 protection_dir=$2 pool_status result status inspection_root record guard_pid
  local -a ignored_pids=()
  FM_WORKTREE_PROTECTION_MODE=
  fm_worktree_meta_local_path "$meta" || return $?
  inspection_root=$(git -C "$FM_WORKTREE_PROTECTION_WORKTREE" worktree list --porcelain 2>/dev/null \
    | sed -n 's/^worktree //p' | head -n 1)
  if [ -z "$inspection_root" ] || [ ! -d "$inspection_root" ]; then
    FM_WORKTREE_PROTECTION_ERROR="could not resolve an inspection root outside recorded worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
    return 2
  fi
  inspection_root=$(fm_worktree_real_or_raw "$inspection_root")
  if [ "$inspection_root" = "$FM_WORKTREE_PROTECTION_WORKTREE" ]; then
    FM_WORKTREE_PROTECTION_ERROR="treehouse inspection root is the recorded worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
    return 2
  fi
  if [ -d "$protection_dir" ] && [ ! -L "$protection_dir" ]; then
    for record in "$protection_dir"/*.protection; do
      [ -f "$record" ] && [ ! -L "$record" ] || continue
      fm_worktree_protection_record_matches \
        "$record" presence "$FM_WORKTREE_PROTECTION_WORKTREE" || continue
      guard_pid=$(fm_worktree_protection_record_value "$record" pid)
      ignored_pids+=("$guard_pid")
    done
  fi
  if ! pool_status=$(CDPATH='' cd -- "$inspection_root" \
    && treehouse status --json 2>/dev/null); then
    FM_WORKTREE_PROTECTION_ERROR="treehouse status failed for recorded worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
    return 2
  fi
  result=$(printf '%s\n' "$pool_status" | node -e '
    const fs = require("fs");
    const path = process.argv[1];
    let rows;
    try { rows = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    if (!Array.isArray(rows)) process.exit(2);
    const row = rows.find((candidate) => candidate && candidate.path === path);
    if (!row) process.exit(3);
    if (typeof row.lease_id === "string" && row.lease_id) {
      process.stdout.write("none");
      process.exit(0);
    }
    if (!Array.isArray(row.processes)) process.exit(2);
    const ignored = new Set(process.argv.slice(2).map((pid) => Number(pid)));
    const occupants = row.processes.filter((process) => {
      if (!process || !Number.isInteger(process.pid)) process.exit(2);
      return !ignored.has(process.pid);
    });
    process.stdout.write(occupants.length ? "presence" : "durable");
  ' "$FM_WORKTREE_PROTECTION_WORKTREE" "${ignored_pids[@]}" 2>/dev/null)
  status=$?
  case "$status" in
    0) FM_WORKTREE_PROTECTION_MODE=$result ;;
    3) return 1 ;;
    *)
      FM_WORKTREE_PROTECTION_ERROR="treehouse status returned invalid JSON for recorded worktree: $FM_WORKTREE_PROTECTION_WORKTREE"
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
