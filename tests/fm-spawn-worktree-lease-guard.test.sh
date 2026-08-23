#!/usr/bin/env bash
# Regression tests for fm-spawn's durable Treehouse lease collision guard.
#
# These drive the real spawn executable with fake Treehouse and tmux surfaces.
# Treehouse returns controlled lease paths while real linked git worktrees prove
# the accepted path still passes the spawn isolation and base-freshness gates.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TEARDOWN="$ROOT/bin/fm-teardown.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease-guard)
BLOCKED_SPAWN_PID=
BLOCKED_TREEHOUSE_PID=
BLOCKED_BARRIER_PID=

cleanup_blocked_spawn() {
  [ -z "$BLOCKED_SPAWN_PID" ] || kill "$BLOCKED_SPAWN_PID" 2>/dev/null || true
  [ -z "$BLOCKED_TREEHOUSE_PID" ] || kill "$BLOCKED_TREEHOUSE_PID" 2>/dev/null || true
  [ -z "$BLOCKED_BARRIER_PID" ] || kill "$BLOCKED_BARRIER_PID" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_blocked_spawn EXIT
trap 'cleanup_blocked_spawn; exit 130' INT
trap 'cleanup_blocked_spawn; exit 143' TERM

make_spawn_fakebin() {
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
  command -v lsof >/dev/null 2>&1 || return 0
  lsof -a -d cwd +D "$path" -t 2>/dev/null || true
}
worktree_in_use() {
  [ -n "$(worktree_pids "$1" | head -n 1)" ]
}
printf '%s\n' "$*" >> "${FM_FAKE_TREEHOUSE_LOG:?FM_FAKE_TREEHOUSE_LOG unset}"
case "${1:-}" in
  get)
    shift
    saw_lease=0
    saw_holder=0
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --lease) saw_lease=1 ;;
        --lease-holder) shift; [ "${1:-}" = "${FM_FAKE_EXPECT_HOLDER:-}" ] && saw_holder=1 ;;
      esac
      shift
    done
    [ "$saw_lease" -eq 1 ] || exit 41
    [ "$saw_holder" -eq 1 ] || exit 42
    count=0
    [ ! -f "$FM_FAKE_TREEHOUSE_COUNT" ] || count=$(cat "$FM_FAKE_TREEHOUSE_COUNT")
    count=$((count + 1))
    printf '%s\n' "$count" > "$FM_FAKE_TREEHOUSE_COUNT"
    path=$(sed -n "${count}p" "$FM_FAKE_TREEHOUSE_SEQUENCE")
    [ -n "$path" ] || path=$(tail -n 1 "$FM_FAKE_TREEHOUSE_SEQUENCE")
    if grep -Fqx -- "$path" "${FM_FAKE_PROTECTED_PATHS:?FM_FAKE_PROTECTED_PATHS unset}" \
      && ! worktree_in_use "$path"; then
      : > "${FM_FAKE_PREACQUIRE_VIOLATION:?FM_FAKE_PREACQUIRE_VIOLATION unset}"
    fi
    if [ "${FM_FAKE_BLOCK_GET:-0}" = 1 ] && [ "$count" -eq 1 ]; then
      worktree_pids "${FM_FAKE_PROTECTED_PATH:?FM_FAKE_PROTECTED_PATH unset}" \
        | head -n 1 > "${FM_FAKE_BARRIER_PID_FILE:?FM_FAKE_BARRIER_PID_FILE unset}"
      printf '%s\n' "$$" > "${FM_FAKE_BLOCK_READY:?FM_FAKE_BLOCK_READY unset}"
      if [ -n "${FM_FAKE_BLOCK_RELEASE:-}" ]; then
        wait_count=0
        while [ ! -e "$FM_FAKE_BLOCK_RELEASE" ] && [ "$wait_count" -lt 200 ]; do
          sleep 0.05
          wait_count=$((wait_count + 1))
        done
        [ -e "$FM_FAKE_BLOCK_RELEASE" ] || exit 44
      else
        wait_count=0
        while [ "$wait_count" -lt 200 ]; do
          sleep 0.05
          wait_count=$((wait_count + 1))
        done
      fi
    fi
    printf '%s\n' "$path"
    ;;
  return) exit 0 ;;
  *) exit 43 ;;
esac
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
  has-session|new-session|new-window|kill-window|send-keys|set-window-option) exit 0 ;;
esac
exit 0
SH
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$fakebin/treehouse" "$fakebin/tmux" "$fakebin/no-mistakes" \
    "$fakebin/gh-axi" "$fakebin/gh"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 id=$2 case_dir home project collision safe fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  collision="$case_dir/collision"
  safe="$case_dir/safe"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$collision" "collision-$name"
  git -C "$project" worktree add --quiet --detach "$safe"
  printf '%s\n' "$case_dir|$home|$project|$collision|$safe|$fakebin"
}

read_case_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJECT_DIR COLLISION_DIR SAFE_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

run_spawn() {
  local id=$1 pane_path=$2 sequence=$3 protected_paths=${4:-$COLLISION_DIR}
  local log="$CASE_DIR/treehouse.log" count="$CASE_DIR/treehouse.count"
  : > "$log"
  rm -f "$count"
  printf '%s\n' "$sequence" > "$CASE_DIR/treehouse.sequence"
  printf '%s\n' "$protected_paths" > "$CASE_DIR/protected-paths"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$pane_path" \
    FM_FAKE_TREEHOUSE_LOG="$log" FM_FAKE_TREEHOUSE_COUNT="$count" \
    FM_FAKE_TREEHOUSE_SEQUENCE="$CASE_DIR/treehouse.sequence" \
    FM_FAKE_PROTECTED_PATH="$COLLISION_DIR" \
    FM_FAKE_PROTECTED_PATHS="$CASE_DIR/protected-paths" \
    FM_FAKE_PREACQUIRE_VIOLATION="$CASE_DIR/preacquire-violation" \
    FM_FAKE_EXPECT_HOLDER="fm-$id" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
}

add_recorded_collision() {
  local index=$1 path
  path="$CASE_DIR/collision-$index"
  git -C "$PROJECT_DIR" worktree add --quiet --detach "$path"
  fm_write_meta "$HOME_DIR/state/live-owner-$index.meta" \
    "window=firstmate:fm-live-owner-$index" "worktree=$path" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'
  printf '%s\n' "$path"
}

test_colliding_lease_is_redrawn() {
  local rec id out status
  id=lease-redraw-r1
  rec=$(make_case redraw "$id")
  read_case_record "$rec"
  fm_write_meta "$HOME_DIR/state/live-owner.meta" \
    'window=firstmate:fm-live-owner' "worktree=$COLLISION_DIR" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'

  out=$(run_spawn "$id" "$SAFE_DIR" "$COLLISION_DIR"$'\n'"$SAFE_DIR")
  status=$?
  expect_code 0 "$status" "spawn should redraw after Treehouse leases a recorded live worktree"
  assert_contains "$out" "spawned $id" "redrawn spawn did not report success"
  assert_grep "worktree=$SAFE_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn did not record the non-colliding redraw"
  [ "$(cat "$CASE_DIR/treehouse.count")" -eq 2 ] \
    || fail "colliding lease was not redrawn exactly once"
  assert_absent "$CASE_DIR/preacquire-violation" \
    "Treehouse reached a recorded path before its exclusion barrier was active"
  assert_no_grep '^return ' "$CASE_DIR/treehouse.log" \
    "spawn returned the colliding worktree instead of preserving its repaired lease"
  pass "a lease colliding with recorded task metadata is rejected and redrawn"
}

test_exhausted_redraw_fails_loudly() {
  local rec id out status collision_2 collision_3 sequence protected
  id=lease-exhausted-r2
  rec=$(make_case exhausted "$id")
  read_case_record "$rec"
  fm_write_meta "$HOME_DIR/state/live-owner.meta" \
    'window=firstmate:fm-live-owner' "worktree=$COLLISION_DIR" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'
  collision_2=$(add_recorded_collision 2)
  collision_3=$(add_recorded_collision 3)
  sequence="$COLLISION_DIR"$'\n'"$collision_2"$'\n'"$collision_3"$'\n'"$COLLISION_DIR"
  protected="$COLLISION_DIR"$'\n'"$collision_2"$'\n'"$collision_3"

  out=$(run_spawn "$id" "$COLLISION_DIR" "$sequence" "$protected")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded after every bounded redraw collided"
  assert_contains "$out" "refusing further redraws after 4 of 4 bounded attempts" \
    "exhausted redraw did not fail with the bounded-attempt diagnostic"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "exhausted redraw published task metadata despite having no safe worktree"
  [ "$(cat "$CASE_DIR/treehouse.count")" -eq 4 ] \
    || fail "exhausted redraw did not stop at the configured attempt bound"
  assert_absent "$CASE_DIR/preacquire-violation" \
    "bounded redraw acquired a recorded path before its exclusion barrier was active"
  pass "an exhausted redraw loop stops at its bound and fails loudly"
}

test_all_distinct_collisions_allow_safe_draw() {
  local rec id out status index collision sequence protected
  id=lease-distinct-r6
  rec=$(make_case distinct "$id")
  read_case_record "$rec"
  fm_write_meta "$HOME_DIR/state/live-owner-1.meta" \
    'window=firstmate:fm-live-owner-1' "worktree=$COLLISION_DIR" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'
  sequence=$COLLISION_DIR
  protected=$COLLISION_DIR
  for index in 2 3 4 5 6 7 8; do
    collision=$(add_recorded_collision "$index")
    sequence="${sequence}"$'\n'"${collision}"
    protected="${protected}"$'\n'"${collision}"
  done
  sequence="${sequence}"$'\n'"${SAFE_DIR}"

  out=$(run_spawn "$id" "$SAFE_DIR" "$sequence" "$protected")
  status=$?
  expect_code 0 "$status" \
    "spawn should request a safe candidate after every distinct recorded collision"
  assert_contains "$out" "spawned $id" \
    "spawn did not accept the safe candidate after all distinct collisions"
  assert_grep "worktree=$SAFE_DIR" "$HOME_DIR/state/$id.meta" \
    "spawn recorded the wrong worktree after exhausting distinct collisions"
  [ "$(cat "$CASE_DIR/treehouse.count")" -eq 9 ] \
    || fail "spawn did not allow one safe draw after eight distinct collisions"
  assert_absent "$CASE_DIR/preacquire-violation" \
    "a distinct recorded path was acquired before its exclusion barrier was active"
  pass "all distinct collisions can be rejected before one safe draw"
}

test_non_colliding_lease_is_unaffected() {
  local rec id out status
  id=lease-direct-r3
  rec=$(make_case direct "$id")
  read_case_record "$rec"

  out=$(run_spawn "$id" "$SAFE_DIR" "$SAFE_DIR")
  status=$?
  expect_code 0 "$status" "a non-colliding durable lease should spawn normally"
  assert_contains "$out" "spawned $id" "non-colliding spawn did not report success"
  assert_grep "worktree=$SAFE_DIR" "$HOME_DIR/state/$id.meta" \
    "non-colliding spawn recorded the wrong worktree"
  [ "$(cat "$CASE_DIR/treehouse.count")" -eq 1 ] \
    || fail "non-colliding lease was unnecessarily redrawn"
  pass "a non-colliding lease is accepted on the first attempt"
}

test_unpublished_lease_is_returned_on_abort() {
  local rec id out status
  id=lease-rollback-r4
  rec=$(make_case rollback "$id")
  read_case_record "$rec"
  printf 'uncommitted fixture\n' > "$SAFE_DIR/untracked.txt"

  out=$(run_spawn "$id" "$SAFE_DIR" "$SAFE_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded with a dirty accepted worktree"
  assert_contains "$out" "is not clean" \
    "dirty accepted worktree did not reach the pre-publication abort path"
  assert_grep "return --force --if-lease-holder fm-$id $SAFE_DIR" \
    "$CASE_DIR/treehouse.log" \
    "spawn abort did not holder-conditionally return its unpublished lease"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "aborted spawn published metadata for its returned lease"
  pass "an accepted lease is holder-conditionally returned when spawn aborts before publication"
}

test_interrupted_acquisition_reaps_barrier() {
  local rec id spawn_pid barrier_pid barrier_identity current_identity status _
  local treehouse_identity current_treehouse_identity
  id=lease-interrupt-r5
  rec=$(make_case interrupt "$id")
  read_case_record "$rec"
  fm_write_meta "$HOME_DIR/state/live-owner.meta" \
    'window=firstmate:fm-live-owner' "worktree=$COLLISION_DIR" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'
  : > "$CASE_DIR/treehouse.log"
  printf '%s\n%s\n' "$COLLISION_DIR" "$SAFE_DIR" > "$CASE_DIR/treehouse.sequence"
  printf '%s\n' "$COLLISION_DIR" > "$CASE_DIR/protected-paths"

  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$SAFE_DIR" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_TREEHOUSE_COUNT="$CASE_DIR/treehouse.count" \
    FM_FAKE_TREEHOUSE_SEQUENCE="$CASE_DIR/treehouse.sequence" \
    FM_FAKE_PROTECTED_PATH="$COLLISION_DIR" \
    FM_FAKE_PROTECTED_PATHS="$CASE_DIR/protected-paths" \
    FM_FAKE_PREACQUIRE_VIOLATION="$CASE_DIR/preacquire-violation" \
    FM_FAKE_EXPECT_HOLDER="fm-$id" FM_FAKE_BLOCK_GET=1 \
    FM_FAKE_BLOCK_READY="$CASE_DIR/block-ready" \
    FM_FAKE_BARRIER_PID_FILE="$CASE_DIR/barrier.pid" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off \
    >"$CASE_DIR/spawn.out" 2>&1 &
  spawn_pid=$!
  BLOCKED_SPAWN_PID=$spawn_pid
  for _ in $(seq 1 60); do
    [ -s "$CASE_DIR/block-ready" ] && [ -s "$CASE_DIR/barrier.pid" ] && break
    sleep 0.05
  done
  [ -s "$CASE_DIR/barrier.pid" ] || fail "blocked acquisition did not expose its cwd barrier"
  BLOCKED_TREEHOUSE_PID=$(cat "$CASE_DIR/block-ready")
  treehouse_identity=$(fm_test_pid_identity "$BLOCKED_TREEHOUSE_PID") \
    || fail "blocked Treehouse acquisition child was not alive"
  barrier_pid=$(cat "$CASE_DIR/barrier.pid")
  BLOCKED_BARRIER_PID=$barrier_pid
  barrier_identity=$(fm_test_pid_identity "$barrier_pid") \
    || fail "blocked acquisition barrier was not alive"

  kill -TERM "$spawn_pid" 2>/dev/null || fail "could not interrupt blocked spawn"
  for _ in $(seq 1 40); do
    kill -0 "$spawn_pid" 2>/dev/null || break
    sleep 0.05
  done
  kill -0 "$spawn_pid" 2>/dev/null \
    && fail "public spawn did not terminate its active Treehouse acquisition child"
  if wait "$spawn_pid"; then
    status=0
  else
    status=$?
  fi
  BLOCKED_SPAWN_PID=
  BLOCKED_TREEHOUSE_PID=
  [ "$status" -ne 0 ] || fail "interrupted spawn reported success"
  current_treehouse_identity=$(fm_test_pid_identity "$BLOCKED_TREEHOUSE_PID" 2>/dev/null || true)
  [ "$current_treehouse_identity" != "$treehouse_identity" ] \
    || fail "public spawn interruption left its Treehouse acquisition child alive"
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    current_identity=$(fm_test_pid_identity "$barrier_pid" 2>/dev/null || true)
    [ "$current_identity" != "$barrier_identity" ] && break
    sleep 0.05
  done
  current_identity=$(fm_test_pid_identity "$barrier_pid" 2>/dev/null || true)
  [ "$current_identity" != "$barrier_identity" ] \
    || fail "interrupted spawn orphaned its pre-acquisition cwd barrier"
  BLOCKED_BARRIER_PID=
  assert_absent "$HOME_DIR/state/$id.meta" \
    "interrupted acquisition published task metadata"
  pass "an interrupted acquisition reaps its temporary cwd barrier"
}

test_teardown_cannot_race_one_slot_acquisition() {
  local rec id owner spawn_pid teardown_out teardown_status spawn_status _
  id=lease-teardown-race-r7
  owner=live-owner
  rec=$(make_case teardown-race "$id")
  read_case_record "$rec"
  fm_write_meta "$HOME_DIR/state/$owner.meta" \
    "window=firstmate:fm-$owner" "endpoint_task_id=$owner" \
    "worktree=$COLLISION_DIR" "project=$PROJECT_DIR" \
    'harness=codex' 'kind=ship' 'mode=local-only'
  : > "$CASE_DIR/treehouse.log"
  printf '%s\n' "$COLLISION_DIR" > "$CASE_DIR/treehouse.sequence"
  printf '%s\n' "$COLLISION_DIR" > "$CASE_DIR/protected-paths"

  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$COLLISION_DIR" \
    FM_FAKE_TREEHOUSE_LOG="$CASE_DIR/treehouse.log" \
    FM_FAKE_TREEHOUSE_COUNT="$CASE_DIR/treehouse.count" \
    FM_FAKE_TREEHOUSE_SEQUENCE="$CASE_DIR/treehouse.sequence" \
    FM_FAKE_PROTECTED_PATH="$COLLISION_DIR" \
    FM_FAKE_PROTECTED_PATHS="$CASE_DIR/protected-paths" \
    FM_FAKE_PREACQUIRE_VIOLATION="$CASE_DIR/preacquire-violation" \
    FM_FAKE_EXPECT_HOLDER="fm-$id" FM_FAKE_BLOCK_GET=1 \
    FM_FAKE_BLOCK_READY="$CASE_DIR/block-ready" \
    FM_FAKE_BLOCK_RELEASE="$CASE_DIR/block-release" \
    FM_FAKE_BARRIER_PID_FILE="$CASE_DIR/barrier.pid" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off \
    >"$CASE_DIR/spawn.out" 2>&1 &
  spawn_pid=$!
  BLOCKED_SPAWN_PID=$spawn_pid
  for _ in $(seq 1 100); do
    [ -s "$CASE_DIR/block-ready" ] && [ -s "$CASE_DIR/barrier.pid" ] && break
    sleep 0.05
  done
  [ -s "$CASE_DIR/block-ready" ] || fail "one-slot acquisition did not reach its blocked Treehouse draw"
  BLOCKED_TREEHOUSE_PID=$(cat "$CASE_DIR/block-ready")
  BLOCKED_BARRIER_PID=$(cat "$CASE_DIR/barrier.pid")

  teardown_out=$(FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEARDOWN_GUARD_DONE=1 \
    PATH="$FAKEBIN_DIR:$PATH" "$TEARDOWN" "$owner" --force 2>&1)
  teardown_status=$?
  [ "$teardown_status" -ne 0 ] \
    || fail "teardown raced a blocked one-slot acquisition"
  assert_contains "$teardown_out" "task set is locked by another operation" \
    "concurrent teardown did not fail at the shared task-set boundary"
  assert_grep "worktree=$COLLISION_DIR" "$HOME_DIR/state/$owner.meta" \
    "concurrent teardown removed the collision owner's metadata"
  assert_no_grep '^return ' "$CASE_DIR/treehouse.log" \
    "concurrent teardown returned the collision path while acquisition was active"

  : > "$CASE_DIR/block-release"
  if wait "$spawn_pid"; then
    spawn_status=0
  else
    spawn_status=$?
  fi
  BLOCKED_SPAWN_PID=
  BLOCKED_TREEHOUSE_PID=
  BLOCKED_BARRIER_PID=
  [ "$spawn_status" -ne 0 ] || fail "one-slot spawn accepted its recorded collision"
  assert_contains "$(cat "$CASE_DIR/spawn.out")" "repeated recorded live task worktree" \
    "one-slot acquisition did not terminate loudly after the protected collision repeated"
  assert_grep "worktree=$COLLISION_DIR" "$HOME_DIR/state/$owner.meta" \
    "collision lease was left without its live metadata owner"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "failed one-slot acquisition published new task metadata"
  assert_absent "$CASE_DIR/preacquire-violation" \
    "one-slot acquisition reached the recorded path without its cwd barrier"
  pass "teardown cannot orphan a lease during one-slot acquisition"
}

test_colliding_lease_is_redrawn
test_exhausted_redraw_fails_loudly
test_all_distinct_collisions_allow_safe_draw
test_non_colliding_lease_is_unaffected
test_unpublished_lease_is_returned_on_abort
test_interrupted_acquisition_reaps_barrier
test_teardown_cannot_race_one_slot_acquisition

echo "# all fm-spawn-worktree-lease-guard tests passed"
