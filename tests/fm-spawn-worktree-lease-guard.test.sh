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
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease-guard)

make_spawn_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
set -u
worktree_in_use() {
  local path=$1 link cwd
  if [ -d /proc ]; then
    for link in /proc/[0-9]*/cwd; do
      cwd=$(readlink "$link" 2>/dev/null || true)
      case "$cwd" in
        "$path"|"$path"/*) return 0 ;;
      esac
    done
    return 1
  fi
  command -v lsof >/dev/null 2>&1 || return 1
  lsof -a -d cwd +D "$path" >/dev/null 2>&1
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
    if [ "$path" = "${FM_FAKE_PROTECTED_PATH:-}" ] && ! worktree_in_use "$path"; then
      : > "${FM_FAKE_PREACQUIRE_VIOLATION:?FM_FAKE_PREACQUIRE_VIOLATION unset}"
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
  chmod +x "$fakebin/treehouse" "$fakebin/tmux"
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
  local id=$1 pane_path=$2 sequence=$3
  local log="$CASE_DIR/treehouse.log" count="$CASE_DIR/treehouse.count"
  : > "$log"
  rm -f "$count"
  printf '%s\n' "$sequence" > "$CASE_DIR/treehouse.sequence"
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_FAKE_PANE_PATH="$pane_path" \
    FM_FAKE_TREEHOUSE_LOG="$log" FM_FAKE_TREEHOUSE_COUNT="$count" \
    FM_FAKE_TREEHOUSE_SEQUENCE="$CASE_DIR/treehouse.sequence" \
    FM_FAKE_PROTECTED_PATH="$COLLISION_DIR" \
    FM_FAKE_PREACQUIRE_VIOLATION="$CASE_DIR/preacquire-violation" \
    FM_FAKE_EXPECT_HOLDER="fm-$id" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJECT_DIR" --mode no-mistakes --yolo off 2>&1
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
  local rec id out status
  id=lease-exhausted-r2
  rec=$(make_case exhausted "$id")
  read_case_record "$rec"
  fm_write_meta "$HOME_DIR/state/live-owner.meta" \
    'window=firstmate:fm-live-owner' "worktree=$COLLISION_DIR" \
    "project=$PROJECT_DIR" 'harness=codex' 'kind=ship'

  out=$(run_spawn "$id" "$COLLISION_DIR" "$COLLISION_DIR")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn succeeded after every bounded redraw collided"
  assert_contains "$out" "could not produce a non-colliding worktree after 8 durable lease attempts" \
    "exhausted redraw did not fail with the bounded-attempt diagnostic"
  assert_absent "$HOME_DIR/state/$id.meta" \
    "exhausted redraw published task metadata despite having no safe worktree"
  [ "$(cat "$CASE_DIR/treehouse.count")" -eq 8 ] \
    || fail "exhausted redraw did not stop at the configured attempt bound"
  assert_absent "$CASE_DIR/preacquire-violation" \
    "bounded redraw acquired a recorded path before its exclusion barrier was active"
  pass "an exhausted redraw loop stops at its bound and fails loudly"
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

test_colliding_lease_is_redrawn
test_exhausted_redraw_fails_loudly
test_non_colliding_lease_is_unaffected
test_unpublished_lease_is_returned_on_abort

echo "# all fm-spawn-worktree-lease-guard tests passed"
