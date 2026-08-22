#!/usr/bin/env bash
# Behavior tests for the locked bootstrap worktree-presence sweep.
#
# A fake local Treehouse status identifies one recorded worktree as pool-owned.
# The real bootstrap executable must start one identity-bound cwd guard, reuse it
# idempotently, and retire it after the task metadata disappears.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOOTSTRAP="$ROOT/bin/fm-bootstrap.sh"
TMP_ROOT=$(fm_test_tmproot fm-worktree-protection)
GUARD_PID=

cleanup_guard() {
  if [ -n "$GUARD_PID" ]; then
    kill "$GUARD_PID" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup_guard EXIT
trap 'cleanup_guard; exit 130' INT
trap 'cleanup_guard; exit 143' TERM

make_treehouse_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  get)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
    ;;
  status)
    [ "${2:-}" = --json ] || exit 1
    printf '[{"path":"%s","lease_id":"%s"}]\n' \
      "${FM_FAKE_TREEHOUSE_PATH:?FM_FAKE_TREEHOUSE_PATH unset}" \
      "${FM_FAKE_TREEHOUSE_LEASE_ID:-}"
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_BOOTSTRAP_NETWORK=skip FM_FAKE_TREEHOUSE_PATH="$WORKTREE_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$BOOTSTRAP" 2>&1
}

test_bootstrap_reestablishes_and_retires_presence_guard() {
  local out record first_pid second_pid recorded_identity current_identity
  HOME_DIR="$TMP_ROOT/home"
  WORKTREE_DIR="$TMP_ROOT/pool-worktree"
  FAKEBIN_DIR=$(make_treehouse_fakebin "$TMP_ROOT/fake")
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" \
    "$HOME_DIR/config" "$WORKTREE_DIR"
  fm_write_meta "$HOME_DIR/state/live-task.meta" \
    'window=firstmate:fm-live-task' "worktree=$WORKTREE_DIR" \
    "project=$TMP_ROOT/project" 'harness=codex' 'kind=ship'

  out=$(FM_BOOTSTRAP_DETECT_ONLY=1 run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "detect-only bootstrap reported a mutating worktree protection sweep"
  assert_absent "$HOME_DIR/state/.worktree-presence/live-task.guard" \
    "detect-only bootstrap created a worktree presence guard"

  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported a protection failure for a valid recorded pool worktree"
  record="$HOME_DIR/state/.worktree-presence/live-task.guard"
  assert_present "$record" "bootstrap did not publish the worktree presence record"
  first_pid=$(sed -n 's/^pid=//p' "$record")
  GUARD_PID=$first_pid
  case "$first_pid" in
    ''|*[!0-9]*) fail "bootstrap recorded an invalid guard pid" ;;
  esac
  recorded_identity=$(sed -n 's/^pid_identity=//p' "$record")
  current_identity=$(fm_test_pid_identity "$first_pid") \
    || fail "bootstrap presence guard is not alive"
  [ "$recorded_identity" = "$current_identity" ] \
    || fail "bootstrap presence record does not bind the live guard identity"

  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "idempotent bootstrap rerun reported a protection failure"
  second_pid=$(sed -n 's/^pid=//p' "$record")
  [ "$second_pid" = "$first_pid" ] \
    || fail "idempotent bootstrap replaced a healthy worktree presence guard"

  rm -f "$HOME_DIR/state/live-task.meta"
  run_bootstrap >/dev/null
  assert_absent "$record" "bootstrap retained a guard record after task retirement"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$first_pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -0 "$first_pid" 2>/dev/null \
    && fail "bootstrap left the retired worktree presence guard running"
  GUARD_PID=

  fm_write_meta "$HOME_DIR/state/durable-task.meta" \
    'window=firstmate:fm-durable-task' "worktree=$WORKTREE_DIR" \
    "project=$TMP_ROOT/project" 'harness=codex' 'kind=ship'
  out=$(FM_FAKE_TREEHOUSE_LEASE_ID=durable-lease run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported a protection failure for an already durable lease"
  assert_absent "$HOME_DIR/state/.worktree-presence/durable-task.guard" \
    "bootstrap added a process guard to an already durable lease"
  pass "bootstrap re-establishes one idempotent guard and retires it with task metadata"
}

test_bootstrap_reestablishes_and_retires_presence_guard

echo "# all fm-worktree-protection tests passed"
