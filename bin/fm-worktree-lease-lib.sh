#!/usr/bin/env bash
# Shared Treehouse worktree lease protection for spawn and bootstrap.
#
# Public functions:
#   fm_treehouse_lease_acquire_noncolliding <state-dir> <project-dir> <holder>
#     Runs a bounded sequence of durable `treehouse get --lease` acquisitions.
#     Every returned path is physically normalized and compared with every
#     worktree= value in <state-dir>/*.meta. A collision is never returned to
#     Treehouse because the just-created durable lease is the repair that keeps
#     the recorded task's directory out of later draws. The function redraws
#     until it sets FM_TREEHOUSE_LEASE_PATH to a non-colliding path or fails
#     loudly after eight attempts.
#   fm_treehouse_lease_return_if_holder <project-dir> <path> <holder>
#     Releases one accepted lease during pre-publication spawn rollback, guarded
#     by Treehouse's holder check so cleanup cannot return another owner's lease.
#   fm_worktree_protection_sweep <state-dir>
#     Re-establishes one long-lived cwd presence guard for every local,
#     Treehouse-managed worktree recorded in task metadata. Treehouse's durable
#     lease state protects new spawns across reboot; this idempotent locked-start
#     sweep covers legacy process-bound tasks whose lease state was lost before
#     they can be migrated by normal teardown. Guard records live under
#     state/.worktree-presence/ and bind pid identity plus physical worktree.
#
# Callers must source fm-wake-lib.sh first for fm_pid_identity. The sweep prints
# WORKTREE_PROTECTION diagnostics only when a recorded Treehouse worktree cannot
# be inspected or protected; successful and non-Treehouse records stay silent.

# shellcheck disable=SC2034 # Read by fm-spawn after acquisition returns.
FM_TREEHOUSE_LEASE_PATH=
FM_TREEHOUSE_COLLISION_OWNER=
FM_TREEHOUSE_COLLISION_ERROR=
FM_WORKTREE_PROTECTION_ERROR=
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

fm_treehouse_lease_acquire_noncolliding() {  # <state-dir> <project-dir> <holder>
  local state=$1 project=$2 holder=$3 attempts=8 attempt=0 candidate rejected=0 collision_status
  FM_TREEHOUSE_LEASE_PATH=
  while [ "$attempt" -lt "$attempts" ]; do
    attempt=$((attempt + 1))
    if ! candidate=$(CDPATH='' cd -- "$project" \
      && treehouse get --lease --lease-holder "$holder"); then
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
        echo "error: treehouse get --lease returned a non-absolute worktree path: '${candidate:-empty}'" >&2
        return 1
        ;;
      /*) ;;
    esac
    if fm_worktree_collision_owner "$state" "$candidate"; then
      rejected=$((rejected + 1))
      echo "warning: treehouse leased recorded live task worktree '$candidate' owned by $FM_TREEHOUSE_COLLISION_OWNER; preserving that durable lease and redrawing ($attempt/$attempts)" >&2
      continue
    else
      collision_status=$?
      if [ "$collision_status" -eq 2 ]; then
        fm_treehouse_lease_return_if_holder "$project" "$candidate" "$holder" >/dev/null 2>&1 || true
        echo "error: cannot verify durable Treehouse lease '$candidate' against task metadata: $FM_TREEHOUSE_COLLISION_ERROR" >&2
        return 1
      fi
    fi
    # shellcheck disable=SC2034 # Read by fm-spawn after this function returns.
    FM_TREEHOUSE_LEASE_PATH=$candidate
    return 0
  done
  echo "error: treehouse could not produce a non-colliding worktree after $attempts durable lease attempts; every lease matched a recorded live task worktree in $state" >&2
  return 1
}

fm_treehouse_lease_return_if_holder() {  # <project-dir> <path> <holder>
  local project=$1 path=$2 holder=$3
  (CDPATH='' cd -- "$project" \
    && treehouse return --force --if-lease-holder "$holder" "$path")
}

fm_worktree_guard_record_value() {  # <record> <key>
  local record=$1 key=$2
  sed -n "s/^${key}=//p" "$record" 2>/dev/null | tail -n 1
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

fm_worktree_guard_record_matches() {  # <record> <worktree>
  local record=$1 worktree=$2 recorded_worktree pid recorded_identity current_identity current_cwd
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  recorded_worktree=$(fm_worktree_guard_record_value "$record" worktree)
  [ "$recorded_worktree" = "$worktree" ] || return 1
  pid=$(fm_worktree_guard_record_value "$record" pid)
  case "$pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  recorded_identity=$(fm_worktree_guard_record_value "$record" pid_identity)
  [ -n "$recorded_identity" ] || return 1
  current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current_identity" = "$recorded_identity" ] || return 1
  current_cwd=$(fm_worktree_process_cwd "$pid") || return 1
  [ "$(fm_worktree_real_or_raw "$current_cwd")" = "$worktree" ]
}

fm_worktree_guard_stop_record() {  # <record>
  local record=$1 pid recorded_identity current_identity
  [ -f "$record" ] && [ ! -L "$record" ] || {
    rm -f -- "$record" 2>/dev/null || true
    return 0
  }
  pid=$(fm_worktree_guard_record_value "$record" pid)
  recorded_identity=$(fm_worktree_guard_record_value "$record" pid_identity)
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

fm_worktree_guard_start() {  # <record> <worktree>
  local record=$1 worktree=$2 pid identity previous_identity='' current_cwd stable=0 tmp _
  # shellcheck disable=SC2016 # $1 is intentionally expanded by the child bash.
  nohup bash -c 'cd "$1" || exit 1; exec sleep 2147483647' \
    fm-worktree-presence "$worktree" </dev/null >/dev/null 2>&1 &
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
    return 1
  fi
  tmp="$record.tmp.${BASHPID:-$$}"
  if ! {
    printf 'pid=%s\n' "$pid"
    printf 'pid_identity=%s\n' "$identity"
    printf 'worktree=%s\n' "$worktree"
  } > "$tmp" || ! mv -f -- "$tmp" "$record"; then
    rm -f -- "$tmp"
    kill "$pid" 2>/dev/null || true
    return 1
  fi
}

fm_worktree_meta_needs_presence() {  # <meta> -> sets FM_WORKTREE_PROTECTION_WORKTREE
  local meta=$1 backend remote worktree worktree_real pool_status match_status
  FM_WORKTREE_PROTECTION_WORKTREE=
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  backend=$(sed -n 's/^backend=//p' "$meta" 2>/dev/null | tail -n 1)
  [ "$backend" != orca ] || return 1
  remote=$(sed -n 's/^remote_host=//p' "$meta" 2>/dev/null | tail -n 1)
  [ -z "$remote" ] || return 1
  worktree=$(sed -n 's/^worktree=//p' "$meta" 2>/dev/null | tail -n 1)
  case "$worktree" in
    /*) ;;
    *) return 1 ;;
  esac
  [ -d "$worktree" ] || {
    FM_WORKTREE_PROTECTION_ERROR="recorded worktree is unavailable: $worktree"
    return 2
  }
  worktree_real=$(fm_worktree_real_or_raw "$worktree")
  FM_WORKTREE_PROTECTION_WORKTREE=$worktree_real
  if ! pool_status=$(CDPATH='' cd -- "$worktree_real" && treehouse status --json 2>/dev/null); then
    FM_WORKTREE_PROTECTION_ERROR="treehouse status failed for recorded worktree: $worktree_real"
    return 2
  fi
  if printf '%s\n' "$pool_status" | node -e '
    const fs = require("fs");
    const path = process.argv[1];
    let rows;
    try { rows = JSON.parse(fs.readFileSync(0, "utf8")); } catch { process.exit(2); }
    if (!Array.isArray(rows)) process.exit(2);
    const row = rows.find((candidate) => candidate && candidate.path === path);
    if (!row) process.exit(1);
    process.exit(typeof row.lease_id === "string" && row.lease_id ? 1 : 0);
  ' "$worktree_real" >/dev/null 2>&1; then
    match_status=0
  else
    match_status=$?
  fi
  case "$match_status" in
    0) ;;
    1) return 1 ;;
    *)
      FM_WORKTREE_PROTECTION_ERROR="treehouse status returned invalid JSON for recorded worktree: $worktree_real"
      return 2
      ;;
  esac
}

fm_worktree_protection_sweep() {  # <state-dir>
  local state=$1 guard_dir record meta id worktree status
  FM_WORKTREE_PROTECTION_ERROR=
  [ -d "$state" ] || return 0
  guard_dir="$state/.worktree-presence"
  if [ -L "$guard_dir" ] || { [ -e "$guard_dir" ] && [ ! -d "$guard_dir" ]; }; then
    echo "WORKTREE_PROTECTION: failed: unsafe guard directory path: $guard_dir"
    return 1
  fi
  mkdir -p "$guard_dir" || {
    echo "WORKTREE_PROTECTION: failed: could not create $guard_dir"
    return 1
  }
  chmod 700 "$guard_dir" 2>/dev/null || true

  for record in "$guard_dir"/*.guard; do
    [ -e "$record" ] || [ -L "$record" ] || continue
    id=$(basename "$record" .guard)
    meta="$state/$id.meta"
    worktree=
    if [ -f "$meta" ] && [ ! -L "$meta" ]; then
      FM_WORKTREE_PROTECTION_ERROR=
      if fm_worktree_meta_needs_presence "$meta" 2>/dev/null; then
        status=0
      else
        status=$?
      fi
      case "$status" in
        0) worktree=$FM_WORKTREE_PROTECTION_WORKTREE ;;
        1) worktree= ;;
        *)
          # A transient inspection error must not tear down a healthy existing
          # guard. The second pass reports the actionable diagnostic.
          worktree=$FM_WORKTREE_PROTECTION_WORKTREE
          ;;
      esac
    fi
    if [ -z "$worktree" ] || ! fm_worktree_guard_record_matches "$record" "$worktree"; then
      fm_worktree_guard_stop_record "$record"
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
    if fm_worktree_meta_needs_presence "$meta"; then
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
        echo "WORKTREE_PROTECTION: task $id: skipped: $FM_WORKTREE_PROTECTION_ERROR"
        continue
        ;;
    esac
    record="$guard_dir/$id.guard"
    fm_worktree_guard_record_matches "$record" "$worktree" && continue
    fm_worktree_guard_stop_record "$record"
    if ! fm_worktree_guard_start "$record" "$worktree"; then
      echo "WORKTREE_PROTECTION: task $id: failed: could not start a presence guard for $worktree"
    fi
  done
}
