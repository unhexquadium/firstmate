#!/usr/bin/env bash
set -u
ROOT=$PWD
export PATH="$ROOT/.test-tmp/tmux-3.5a:$PATH"
export FM_HOME="$ROOT/l" TMPDIR="$ROOT/.test-tmp"
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM TMUX
mkdir -p "$FM_HOME/projects/probe" "$FM_HOME/data/guard-probe"
git -C "$FM_HOME/projects/probe" init -q -b main
printf 'claude\n' > "$FM_HOME/config/crew-harness"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf '# Task\n## Captain\x27s intent\nValidate worker launch refusal.\n## Firstmate spec\nDo not perform work.\n' > "$FM_HOME/data/guard-probe/brief.md"
for value in 'crew mate' '$(touch pwned)' 'crew;mate' '-rf' ':crewmate' 'a:b:c' $'crewmate\nscout' ''; do
  printf '%s\n' "$value" > "$FM_HOME/config/crew-claude-agent"
  printf '\nINPUT=%q\n' "$value"
  FM_SPAWN_NO_GUARD=1 bin/fm-spawn.sh guard-probe "$FM_HOME/projects/probe" --harness claude --mode local-only --yolo off
  status=$?
  printf 'exit=%s; metadata_exists=%s; project_worktrees=' "$status" "$([ -e "$FM_HOME/state/guard-probe.meta" ] && echo yes || echo no)"
  git -C "$FM_HOME/projects/probe" worktree list --porcelain | awk '/^worktree / {n++} END{print n}'
  [ "$status" = 1 ] && [ ! -e "$FM_HOME/state/guard-probe.meta" ] || exit 1
done
