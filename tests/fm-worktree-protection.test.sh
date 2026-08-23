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
AGENT_PID=
SHELL_PID=
UNKNOWN_PID=

cleanup_guard() {
  if [ -n "$GUARD_PID" ]; then
    kill "$GUARD_PID" 2>/dev/null || true
  fi
  if [ -n "$AGENT_PID" ]; then
    kill "$AGENT_PID" 2>/dev/null || true
  fi
  if [ -n "$SHELL_PID" ]; then
    kill "$SHELL_PID" 2>/dev/null || true
  fi
  if [ -n "$UNKNOWN_PID" ]; then
    kill "$UNKNOWN_PID" 2>/dev/null || true
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
worktree_pids() {
  local path=$1 link cwd pid
  if [ -d /proc ]; then
    for link in /proc/[0-9]*/cwd; do
      cwd=$(readlink "$link" 2>/dev/null || true)
      case "$cwd" in
        "$path"|"$path"/*)
          pid=${link#/proc/}
          printf '%s\n' "${pid%/cwd}"
          ;;
      esac
    done
    return
  fi
  lsof -a -d cwd +D "$path" -t 2>/dev/null || true
}
case "${1:-}" in
  get)
    [ "${2:-}" = --help ] || exit 1
    printf '%s\n' 'Usage: treehouse get [--lease] [--lease-holder <holder>]'
    ;;
  status)
    [ "${2:-}" = --json ] || exit 1
    if [ -n "${FM_FAKE_TREEHOUSE_STATUS_CWDS:-}" ]; then
      pwd -P >> "$FM_FAKE_TREEHOUSE_STATUS_CWDS"
    fi
    if [ "${FM_FAKE_TREEHOUSE_MEMBER:-1}" = 0 ]; then
      printf '[]\n'
      exit 0
    fi
    processes='['
    separator=
    while IFS= read -r pid; do
      case "$pid" in ''|*[!0-9]*) continue ;; esac
      processes="${processes}${separator}{\"pid\":${pid},\"name\":\"process\"}"
      separator=,
    done < <(worktree_pids "${FM_FAKE_TREEHOUSE_PATH:?FM_FAKE_TREEHOUSE_PATH unset}" | sort -un)
    processes="${processes}]"
    status_path=${FM_FAKE_TREEHOUSE_STATUS_PATH:-${FM_FAKE_TREEHOUSE_PATH:?FM_FAKE_TREEHOUSE_PATH unset}}
    printf '[{"path":"%s","lease_id":"%s","processes":%s}]\n' \
      "$status_path" \
      "${FM_FAKE_TREEHOUSE_LEASE_ID:-}" \
      "$processes"
    ;;
  *) exit 1 ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) printf '%s\n' 'fm-live-task' ;;
  display-message)
    case "$*" in
      *'#{pane_current_command}'*) printf '%s\n' "${FM_FAKE_AGENT_COMMAND:-bash}" ;;
      *'#{pane_tty}'*) printf '\n' ;;
      *) exit 1 ;;
    esac
    ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

run_bootstrap() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_BOOTSTRAP_NETWORK=skip FM_FAKE_TREEHOUSE_PATH="$WORKTREE_DIR" \
    FM_FAKE_TREEHOUSE_STATUS_CWDS="$HOME_DIR/treehouse-status-cwds" \
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
  PROJECT_DIR="$TMP_ROOT/project"
  WORKTREE_DIR="$TMP_ROOT/pool-worktree"
  FAKEBIN_DIR=$(make_treehouse_fakebin "$TMP_ROOT/fake")
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" \
    "$HOME_DIR/config"
  fm_git_worktree "$PROJECT_DIR" "$WORKTREE_DIR" protection-live
  fm_write_meta "$HOME_DIR/state/live-task.meta" \
    'window=firstmate:fm-live-task' "worktree=$WORKTREE_DIR" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'

  out=$(FM_BOOTSTRAP_DETECT_ONLY=1 run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "detect-only bootstrap reported a mutating worktree protection sweep"
  assert_absent "$HOME_DIR/state/.worktree-protection/live-task.protection" \
    "detect-only bootstrap registered worktree protection"

  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported a protection failure for a quiescent pool worktree"
  record="$HOME_DIR/state/.worktree-protection/live-task.protection"
  assert_present "$record" "bootstrap did not publish durable quiescent protection"
  assert_grep 'mode=durable' "$record" \
    "quiescent worktree did not receive durable protection"
  assert_no_grep 'pid=' "$record" \
    "quiescent worktree was relaxed to a process-presence guard"
  [ "$(tail -n 1 "$HOME_DIR/treehouse-status-cwds")" = "$PROJECT_DIR" ] \
    || fail "bootstrap inspected occupancy from inside the candidate worktree"

  bash -c 'cd "$1" || exit 1; exec sleep 2147483647' \
    fm-test-endpoint-shell "$WORKTREE_DIR" </dev/null >/dev/null 2>&1 &
  AGENT_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(readlink "/proc/$AGENT_PID/cwd" 2>/dev/null || true)" = "$WORKTREE_DIR" ] && break
    sleep 0.05
  done
  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "idle endpoint shell caused a worktree protection failure"
  assert_grep 'mode=durable' "$record" \
    "idle endpoint shell was misclassified as a live agent"

  out=$(FM_FAKE_AGENT_COMMAND=codex run_bootstrap)
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

  out=$(FM_FAKE_AGENT_COMMAND=codex run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "idempotent presence-guard rerun reported a failure"
  second_pid=$(sed -n 's/^pid=//p' "$record")
  [ "$second_pid" = "$first_pid" ] \
    || fail "idempotent bootstrap replaced a healthy worktree presence guard"

  run_bootstrap >/dev/null
  assert_grep 'mode=durable' "$record" \
    "quiescent transition did not replace presence with durable protection"
  assert_no_grep 'pid=' "$record" \
    "quiescent transition retained process-only protection"
  assert_guard_stops "$first_pid"
  GUARD_PID=
  kill "$AGENT_PID" 2>/dev/null || true
  wait "$AGENT_PID" 2>/dev/null || true
  AGENT_PID=

  rm -f "$HOME_DIR/state/live-task.meta"
  run_bootstrap >/dev/null
  assert_absent "$record" "bootstrap retained protection after task retirement"

  fm_write_meta "$HOME_DIR/state/leased-task.meta" \
    'window=firstmate:fm-leased-task' "worktree=$WORKTREE_DIR" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'
  out=$(FM_FAKE_TREEHOUSE_LEASE_ID=durable-lease run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported a protection failure for an already durable lease"
  assert_absent "$HOME_DIR/state/.worktree-protection/leased-task.protection" \
    "bootstrap duplicated an existing Treehouse durable lease"
  pass "bootstrap splits quiescent durable protection from occupied presence guards"
}

test_bootstrap_skips_plain_clone_worktree() {
  local out
  HOME_DIR="$TMP_ROOT/plain-home"
  PROJECT_DIR="$TMP_ROOT/plain-project"
  WORKTREE_DIR="$TMP_ROOT/plain-clone"
  FAKEBIN_DIR=$(make_treehouse_fakebin "$TMP_ROOT/plain-fake")
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" \
    "$HOME_DIR/config"
  fm_git_init_commit "$PROJECT_DIR"
  git clone --quiet "$PROJECT_DIR" "$WORKTREE_DIR"
  fm_write_meta "$HOME_DIR/state/plain-secondmate.meta" \
    'window=firstmate:fm-plain-secondmate' "worktree=$WORKTREE_DIR" \
    "project=$WORKTREE_DIR" 'harness=codex' 'kind=secondmate'

  out=$(FM_FAKE_TREEHOUSE_MEMBER=0 run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported plain-clone secondmate home as a protection failure"
  assert_absent "$HOME_DIR/state/.worktree-protection/plain-secondmate.protection" \
    "bootstrap registered pool protection for a plain-clone secondmate home"
  pass "bootstrap silently excludes plain-clone secondmate homes from pool protection"
}

test_bootstrap_protects_symlinked_treehouse_root() {
  local out physical_root symlink_root symlink_worktree record
  HOME_DIR="$TMP_ROOT/symlink-home"
  PROJECT_DIR="$TMP_ROOT/symlink-project"
  physical_root="$TMP_ROOT/treehouse-physical"
  symlink_root="$TMP_ROOT/treehouse-link"
  WORKTREE_DIR="$physical_root/pool-worktree"
  symlink_worktree="$symlink_root/pool-worktree"
  FAKEBIN_DIR=$(make_treehouse_fakebin "$TMP_ROOT/symlink-fake")
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" \
    "$HOME_DIR/config" "$physical_root"
  ln -s "$physical_root" "$symlink_root"
  fm_git_worktree "$PROJECT_DIR" "$WORKTREE_DIR" symlink-protection
  fm_write_meta "$HOME_DIR/state/symlink-task.meta" \
    'window=firstmate:fm-symlink-task' "worktree=$symlink_worktree" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'

  out=$(FM_FAKE_TREEHOUSE_STATUS_PATH="$symlink_worktree" run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "bootstrap reported a protection failure for a symlinked Treehouse root"
  record="$HOME_DIR/state/.worktree-protection/symlink-task.protection"
  assert_present "$record" \
    "bootstrap skipped a recorded worktree beneath a symlinked Treehouse root"
  assert_grep 'mode=durable' "$record" \
    "symlinked Treehouse worktree did not receive durable protection"
  assert_grep "worktree=$WORKTREE_DIR" "$record" \
    "symlinked Treehouse worktree protection was not physically normalized"
  pass "bootstrap protects worktrees beneath symlinked Treehouse roots"
}

test_unverified_backends_use_structural_agent_occupancy() {
  local backend out record first_pid fifo _
  for backend in zellij cmux; do
    HOME_DIR="$TMP_ROOT/$backend-home"
    PROJECT_DIR="$TMP_ROOT/$backend-project"
    WORKTREE_DIR="$TMP_ROOT/$backend-worktree"
    FAKEBIN_DIR=$(make_treehouse_fakebin "$TMP_ROOT/$backend-fake")
    mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" \
      "$HOME_DIR/config"
    fm_git_worktree "$PROJECT_DIR" "$WORKTREE_DIR" "$backend-live"
    fm_write_meta "$HOME_DIR/state/$backend-task.meta" \
      "window=$backend-endpoint" "worktree=$WORKTREE_DIR" \
      "project=$PROJECT_DIR" 'harness=codex' 'kind=ship' "backend=$backend"
    fifo="$TMP_ROOT/$backend-shell.fifo"
    mkfifo "$fifo"
    bash -c 'cd "$1" || exit 1; read -r _ < "$2"' \
      fm-test-shell "$WORKTREE_DIR" "$fifo" </dev/null >/dev/null 2>&1 &
    SHELL_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$(readlink "/proc/$SHELL_PID/cwd" 2>/dev/null || true)" = "$WORKTREE_DIR" ] && break
      sleep 0.05
    done

    out=$(run_bootstrap)
    assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
      "$backend idle shell made structural occupancy uncertain"
    record="$HOME_DIR/state/.worktree-protection/$backend-task.protection"
    assert_grep 'mode=durable' "$record" \
      "$backend idle shell was classified as a live agent"

    bash -c 'cd "$1" || exit 1; exec -a codex sleep 2147483647' \
      fm-test-agent "$WORKTREE_DIR" </dev/null >/dev/null 2>&1 &
    AGENT_PID=$!
    for _ in 1 2 3 4 5 6 7 8 9 10; do
      [ "$(readlink "/proc/$AGENT_PID/cwd" 2>/dev/null || true)" = "$WORKTREE_DIR" ] && break
      sleep 0.05
    done
    run_bootstrap >/dev/null
    assert_grep 'mode=presence' "$record" \
      "$backend live recorded harness did not receive presence protection"
    first_pid=$(sed -n 's/^pid=//p' "$record")
    GUARD_PID=$first_pid

    kill "$AGENT_PID" 2>/dev/null || true
    wait "$AGENT_PID" 2>/dev/null || true
    AGENT_PID=
    run_bootstrap >/dev/null
    assert_grep 'mode=durable' "$record" \
      "$backend worktree did not become durable after its real agent exited"
    assert_guard_stops "$first_pid"
    GUARD_PID=
    kill "$SHELL_PID" 2>/dev/null || true
    wait "$SHELL_PID" 2>/dev/null || true
    SHELL_PID=
    rm -f "$fifo"
  done
  pass "unverified backends structurally distinguish live agents from idle shells"
}

test_unverified_backend_refuses_uncertain_process() {
  local out
  HOME_DIR="$TMP_ROOT/uncertain-home"
  PROJECT_DIR="$TMP_ROOT/uncertain-project"
  WORKTREE_DIR="$TMP_ROOT/uncertain-worktree"
  FAKEBIN_DIR=$(make_treehouse_fakebin "$TMP_ROOT/uncertain-fake")
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" \
    "$HOME_DIR/config"
  fm_git_worktree "$PROJECT_DIR" "$WORKTREE_DIR" uncertain-live
  fm_write_meta "$HOME_DIR/state/uncertain-task.meta" \
    'window=uncertain-endpoint' "worktree=$WORKTREE_DIR" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship' 'backend=zellij'
  bash -c 'cd "$1" || exit 1; exec sleep 2147483647' \
    fm-test-unknown "$WORKTREE_DIR" </dev/null >/dev/null 2>&1 &
  UNKNOWN_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(readlink "/proc/$UNKNOWN_PID/cwd" 2>/dev/null || true)" = "$WORKTREE_DIR" ] && break
    sleep 0.05
  done

  out=$(run_bootstrap)
  assert_contains "$out" 'WORKTREE_PROTECTION: task uncertain-task: skipped: cannot attribute worktree process' \
    "unattributable worktree process did not fail protection loudly"
  assert_absent "$HOME_DIR/state/.worktree-protection/uncertain-task.protection" \
    "unattributable worktree process was silently recorded as quiescent"
  kill "$UNKNOWN_PID" 2>/dev/null || true
  wait "$UNKNOWN_PID" 2>/dev/null || true
  UNKNOWN_PID=
  pass "unverified backend refuses uncertain worktree process occupancy"
}

test_raw_shell_harness_distinguishes_idle_endpoint() {
  local out record idle_fifo raw_fifo _
  HOME_DIR="$TMP_ROOT/raw-shell-home"
  PROJECT_DIR="$TMP_ROOT/raw-shell-project"
  WORKTREE_DIR="$TMP_ROOT/raw-shell-worktree"
  FAKEBIN_DIR=$(make_treehouse_fakebin "$TMP_ROOT/raw-shell-fake")
  mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects" \
    "$HOME_DIR/config"
  fm_git_worktree "$PROJECT_DIR" "$WORKTREE_DIR" raw-shell-live
  fm_write_meta "$HOME_DIR/state/raw-shell-task.meta" \
    'window=raw-shell-endpoint' "worktree=$WORKTREE_DIR" \
    "project=$PROJECT_DIR" 'harness=bash' 'kind=ship' 'backend=zellij'
  idle_fifo="$TMP_ROOT/raw-shell-idle.fifo"
  raw_fifo="$TMP_ROOT/raw-shell-active.fifo"
  mkfifo "$idle_fifo" "$raw_fifo"
  exec 8<> "$idle_fifo"
  exec 9<> "$raw_fifo"
  bash -c 'cd "$1" || exit 1; exec bash --noprofile --norc' \
    fm-test-idle-shell "$WORKTREE_DIR" <&8 >/dev/null 2>&1 &
  SHELL_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(readlink "/proc/$SHELL_PID/cwd" 2>/dev/null || true)" = "$WORKTREE_DIR" ] && break
    sleep 0.05
  done

  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "idle endpoint shell made a shell-named raw harness uncertain"
  record="$HOME_DIR/state/.worktree-protection/raw-shell-task.protection"
  assert_grep 'mode=durable' "$record" \
    "idle endpoint shell was misclassified as a live raw agent"

  bash -lc 'cd "$1" || exit 1; read -r _ < "$2"' \
    fm-test-raw-shell "$WORKTREE_DIR" "$raw_fifo" <&9 >/dev/null 2>&1 &
  AGENT_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(readlink "/proc/$AGENT_PID/cwd" 2>/dev/null || true)" = "$WORKTREE_DIR" ] && break
    sleep 0.05
  done
  out=$(run_bootstrap)
  assert_contains "$out" 'WORKTREE_PROTECTION: task raw-shell-task: skipped: cannot attribute worktree process' \
    "active shell-named raw harness did not fail protection loudly"
  assert_grep 'mode=durable' "$record" \
    "uncertain shell-named raw harness discarded its existing durable exclusion"

  kill "$AGENT_PID" 2>/dev/null || true
  wait "$AGENT_PID" 2>/dev/null || true
  AGENT_PID=
  bash -c 'cd "$1" || exit 1; exec bash -i' \
    fm-test-interactive-raw-shell "$WORKTREE_DIR" <&9 >/dev/null 2>&1 &
  AGENT_PID=$!
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    [ "$(readlink "/proc/$AGENT_PID/cwd" 2>/dev/null || true)" = "$WORKTREE_DIR" ] && break
    sleep 0.05
  done
  out=$(run_bootstrap)
  assert_contains "$out" 'WORKTREE_PROTECTION: task raw-shell-task: skipped: cannot attribute worktree process' \
    "interactive shell-named raw harness was misclassified as an idle endpoint"
  assert_grep 'mode=durable' "$record" \
    "uncertain interactive raw harness discarded its durable exclusion"
  kill -KILL "$AGENT_PID" 2>/dev/null || true
  wait "$AGENT_PID" 2>/dev/null || true
  AGENT_PID=
  out=$(run_bootstrap)
  assert_not_contains "$out" 'WORKTREE_PROTECTION:' \
    "raw shell exit did not restore quiescent protection"
  assert_grep 'mode=durable' "$record" \
    "raw shell exit did not transition to durable protection"
  kill "$SHELL_PID" 2>/dev/null || true
  wait "$SHELL_PID" 2>/dev/null || true
  SHELL_PID=
  exec 8>&-
  exec 9>&-
  rm -f "$idle_fifo" "$raw_fifo"
  pass "raw shell harness distinguishes idle endpoint from uncertain work"
}

test_bootstrap_splits_durable_and_presence_protection
test_bootstrap_skips_plain_clone_worktree
test_bootstrap_protects_symlinked_treehouse_root
test_unverified_backends_use_structural_agent_occupancy
test_unverified_backend_refuses_uncertain_process
test_raw_shell_harness_distinguishes_idle_endpoint

echo "# all fm-worktree-protection tests passed"
