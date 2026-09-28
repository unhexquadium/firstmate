#!/usr/bin/env bash
set -eu
E=/home/kalvira/.no-mistakes/evidence/01M3MX6YJKS699PE403N0MND3T
run_spawn() { bwrap --ro-bind / / --bind "$PWD" "$PWD" --bind "$PWD/l/tmp" /tmp --ro-bind "$HOME/.claude/.credentials.json" "$PWD/l/user/.claude/.credentials.json" --proc /proc --dev /dev bash .test-tmp/spawn-live.sh "$@"; }
mkdir -p l/data/scout-c l/data/ship-d l/data/ship-e
for id in scout-c ship-d ship-e; do cp l/data/guard-probe/brief.md "l/data/$id/brief.md"; done
run_spawn scout-c "$PWD/l/projects/probe" --scout --harness claude --model haiku --effort low > "$E/live-scout.log" 2>&1
rm l/config/crew-claude-agent
run_spawn ship-d "$PWD/l/projects/probe" --mode local-only --yolo off --harness claude --model haiku --effort low > "$E/live-absent.log" 2>&1
printf 'crew mate\n' > l/config/crew-claude-agent
run_spawn ship-e "$PWD/l/projects/probe" --mode local-only --yolo off --harness codex > "$E/live-codex.log" 2>&1
