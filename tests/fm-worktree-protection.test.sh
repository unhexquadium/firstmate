#!/usr/bin/env bash
# Behavior tests for the locked bootstrap worktree-protection sweep.
#
# A fake local Treehouse status distinguishes quiescent, occupied, and already
# leased worktrees. The real bootstrap executable must register durable
# exclusions only for quiescent paths and identity-bound cwd guards only for
# occupied paths, then retire either form with task metadata.
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
    printf '[{"path":"%s","lease_id":"%s","processes":%s}]\n' \
      "${FM_FAKE_TREEHOUSE_PATH:?FM_FAKE_TREEHOUSE_PATH unset}" \
      "${FM_FAKE_TREEHOUSE_LEASE_ID:-}" \
      "${FM_FAKE_TREEHOUSE_PROCESSES:-[]}"
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
    FM_FAKE_TREEHOUSE_PROCESSES="${TREEHOUSE_PROCESSES:-[]}" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$BOOTSTRAP" 2>&1
}

assert_guard_stops() {
  local pid=$1 _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    kill -0 "$pid" 2>/dev/null || return 0
    sleep 0.05
  done
  fail "bootstrap left retired worktree presence guard $pid running"
}

test_bootstrap_splits_durable_and_presence_protection() {
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
  assert_absent "$HOME_DIR/state/.worktree-protection/live-task.protection" \
    "detect-only bootstrap registered worktree protection"

  TREEHOUSE_PROCESSES=[]
  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported a protection failure for a quiescent pool worktree"
  record="$HOME_DIR/state/.worktree-protection/live-task.protection"
  assert_present "$record" "bootstrap did not publish durable quiescent protection"
  assert_grep 'mode=durable' "$record" \
    "quiescent worktree did not receive durable protection"
  assert_no_grep 'pid=' "$record" \
    "quiescent worktree was relaxed to a process-presence guard"

  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "idempotent durable-protection rerun reported a failure"
  assert_grep 'mode=durable' "$record" \
    "idempotent bootstrap replaced durable protection with presence"

  TREEHOUSE_PROCESSES='[{"pid":4242,"name":"agent"}]'
  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported a protection failure for an occupied pool worktree"
  assert_grep 'mode=presence' "$record" \
    "occupied worktree did not receive a presence guard"
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
    "idempotent presence-guard rerun reported a failure"
  second_pid=$(sed -n 's/^pid=//p' "$record")
  [ "$second_pid" = "$first_pid" ] \
    || fail "idempotent bootstrap replaced a healthy worktree presence guard"

  TREEHOUSE_PROCESSES=[]
  run_bootstrap >/dev/null
  assert_grep 'mode=durable' "$record" \
    "quiescent transition did not replace presence with durable protection"
  assert_no_grep 'pid=' "$record" \
    "quiescent transition retained process-only protection"
  assert_guard_stops "$first_pid"
  GUARD_PID=

  rm -f "$HOME_DIR/state/live-task.meta"
  run_bootstrap >/dev/null
  assert_absent "$record" "bootstrap retained protection after task retirement"

  fm_write_meta "$HOME_DIR/state/leased-task.meta" \
    'window=firstmate:fm-leased-task' "worktree=$WORKTREE_DIR" \
    "project=$TMP_ROOT/project" 'harness=codex' 'kind=ship'
  out=$(FM_FAKE_TREEHOUSE_LEASE_ID=durable-lease run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported a protection failure for an already durable lease"
  assert_absent "$HOME_DIR/state/.worktree-protection/leased-task.protection" \
    "bootstrap duplicated an existing Treehouse durable lease"
  pass "bootstrap splits quiescent durable protection from occupied presence guards"
}

test_bootstrap_splits_durable_and_presence_protection

echo "# all fm-worktree-protection tests passed"
