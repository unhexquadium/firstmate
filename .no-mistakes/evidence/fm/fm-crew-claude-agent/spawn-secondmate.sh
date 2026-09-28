#!/usr/bin/env bash
set -eu
export HOME="$PWD/l/user" FM_HOME="$PWD/l" TMPDIR="$PWD/l/tmp" TREEHOUSE_ROOT="$PWD/l/pool" TMUX_TMPDIR="$PWD/l/tmux"
export XDG_CACHE_HOME="$PWD/l/cache" XDG_CONFIG_HOME="$PWD/l/user/.config" XDG_DATA_HOME="$PWD/l/user/.local/share" SHELL=/bin/bash
export PATH="$PWD/.test-tmp/tmux-3.5a:$PATH"
unset FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE CLAUDE_CONFIG_DIR CLAUDECODE CLAUDE_CODE_ENTRYPOINT FM_TEST_SEAM FM_TASK_ID
export TMUX=$(tmux -L fm-lab display-message -p '#{socket_path},#{pid},0')
export FM_SPAWN_NO_GUARD=1
exec .test-tmp/code/bin/fm-spawn.sh "$@"
