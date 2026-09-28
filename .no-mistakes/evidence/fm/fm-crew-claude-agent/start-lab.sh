#!/usr/bin/env bash
set -eu
export HOME="$PWD/l/user" FM_HOME="$PWD/l" TMPDIR="$PWD/l/tmp" TREEHOUSE_ROOT="$PWD/l/pool" TMUX_TMPDIR="$PWD/l/tmux"
export XDG_CACHE_HOME="$PWD/l/cache" XDG_CONFIG_HOME="$PWD/l/user/.config" XDG_DATA_HOME="$PWD/l/user/.local/share" SHELL=/bin/bash
export PATH="$PWD/.test-tmp/tmux-3.5a:$PATH"
unset NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE CLAUDE_CONFIG_DIR CLAUDECODE CLAUDE_CODE_ENTRYPOINT TMUX FM_TASK_ID
exec tmux -L fm-lab -f /dev/null new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$FM_HOME" 'claude --permission-mode auto --model haiku'
