#!/usr/bin/env bash
set -u

ROOT=${1:?repository root required}
BASE_COMMIT=${2:?base commit required}
CASE_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-large-fleet-e2e.XXXXXX")
trap 'rm -rf "$CASE_ROOT"' EXIT

HOME_FIXTURE="$CASE_ROOT/home"
FAKEBIN="$CASE_ROOT/fakebin"
BASE_BIN="$CASE_ROOT/base-bin"
mkdir -p "$HOME_FIXTURE/state" "$HOME_FIXTURE/data" "$HOME_FIXTURE/config" \
  "$HOME_FIXTURE/projects" "$FAKEBIN" "$BASE_BIN"

cp -R "$ROOT/bin/." "$BASE_BIN/"
git -C "$ROOT" show "$BASE_COMMIT:bin/fm-fleet-snapshot.sh" > "$BASE_BIN/fm-fleet-snapshot.sh"
chmod +x "$BASE_BIN/fm-fleet-snapshot.sh"

printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$FAKEBIN/no-mistakes"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'case "${1:-}" in' \
  '  list-windows) sed -n '\''s/^window=[^:]*://p'\'' "${FM_HOME:?}"/state/*.meta ;;' \
  '  display-message) printf '\''codex\n'\'' ;;' \
  '  capture-pane) printf '\''all quiet\n> \n'\'' ;;' \
  'esac' \
  'exit 0' > "$FAKEBIN/tmux"
chmod +x "$FAKEBIN/no-mistakes" "$FAKEBIN/tmux"

PAYLOAD=$(printf '%*s' 40000 '' | tr ' ' x)
for i in $(seq 1 29); do
  id=$(printf 'large-task-%02d' "$i")
  printf '%s\n' \
    "window=firstmate:fm-$id" \
    'project=alpha' \
    'harness=codex' \
    'kind=ship' \
    'mode=ship' > "$HOME_FIXTURE/state/$id.meta"
  printf 'needs-decision [key=%s]: %s\n' "$id" "$PAYLOAD" > "$HOME_FIXTURE/state/$id.status"
done

printf '$ base fm-fleet-snapshot.sh --json with 29 task metas and 40000-byte decision summaries\n'
set +e
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_SNAPSHOT_NOW=2026-08-22T20:00:00Z \
  "$BASE_BIN/fm-fleet-snapshot.sh" --json > "$CASE_ROOT/base-large.json" 2> "$CASE_ROOT/base-large.err"
base_rc=$?
set -e
printf 'exit=%s\n' "$base_rc"
sed -n '1,3p' "$CASE_ROOT/base-large.err"

printf '\n$ target fm-fleet-snapshot.sh --json with the same 29-meta fleet\n'
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_SNAPSHOT_NOW=2026-08-22T20:00:00Z \
  "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$CASE_ROOT/target-large.json"
jq '{schema, task_count:(.tasks|length), max_decision_summary_bytes:([.tasks[].hints.open_decisions[].summary|length]|max), main_inventory_valid:.main_inventory.valid}' \
  "$CASE_ROOT/target-large.json"

printf '\n$ target fm-fleet-snapshot.sh --secondmate-home-summary with the same 29-meta fleet\n'
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_SNAPSHOT_NOW=2026-08-22T20:00:00Z \
  "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary > "$CASE_ROOT/target-home-summary.json"
jq '{schema, endpoint_count:.counts.endpoints, decision_count:.counts.decisions_open, shown_endpoints:(.endpoints|length), omitted}' \
  "$CASE_ROOT/target-home-summary.json"

printf '\n$ target fm-fleet-view.sh with the same 29-meta fleet (representative rendered rows)\n'
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_SNAPSHOT_NOW=2026-08-22T20:00:00Z \
  "$ROOT/bin/fm-fleet-view.sh" | awk 'NR <= 11 || /large-task-29/'

printf '\n$ byte-for-byte normal-case comparison: base vs target with two ordinary task metas\n'
rm -f "$HOME_FIXTURE/state"/large-task-{03..29}.meta "$HOME_FIXTURE/state"/large-task-{03..29}.status
printf 'working: ordinary status\n' > "$HOME_FIXTURE/state/large-task-01.status"
printf 'done: ordinary status\n' > "$HOME_FIXTURE/state/large-task-02.status"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_SNAPSHOT_NOW=2026-08-22T20:00:00Z \
  "$BASE_BIN/fm-fleet-snapshot.sh" --json > "$CASE_ROOT/base-normal.json"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_FIXTURE" FM_ROOT_OVERRIDE="$ROOT" \
  FM_SNAPSHOT_NOW=2026-08-22T20:00:00Z \
  "$ROOT/bin/fm-fleet-snapshot.sh" --json > "$CASE_ROOT/target-normal.json"
if cmp -s "$CASE_ROOT/base-normal.json" "$CASE_ROOT/target-normal.json"; then
  printf 'identical=yes\n'
  sha256sum "$CASE_ROOT/base-normal.json" | awk '{print "sha256=" $1}'
else
  printf 'identical=no\n'
  exit 1
fi

if [ "$base_rc" -eq 0 ]; then
  printf 'expected the base snapshot to reproduce the argv failure\n' >&2
  exit 1
fi
