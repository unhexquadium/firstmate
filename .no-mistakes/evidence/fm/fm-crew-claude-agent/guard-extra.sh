#!/usr/bin/env bash
set -u
E=/home/kalvira/.no-mistakes/evidence/01M3MX6YJKS699PE403N0MND3T
run_spawn() { bwrap --ro-bind / / --bind "$PWD" "$PWD" --bind "$PWD/l/tmp" /tmp --ro-bind "$HOME/.claude/.credentials.json" "$PWD/l/user/.claude/.credentials.json" --proc /proc --dev /dev bash .test-tmp/spawn-live.sh "$@"; }
before=$(sha256sum l/state/ship-h.meta)
for kind in scout relaunch unreadable overlong; do
 printf '\nCASE=%s\n' "$kind"
 case "$kind" in
 scout) run_spawn invalid-scout "$PWD/l/projects/probe" --scout --harness claude ;;
 relaunch) run_spawn ship-h --relaunch ;;
 unreadable) chmod 000 l/config/crew-claude-agent; run_spawn invalid-unreadable "$PWD/l/projects/probe" --scout --harness claude ;;
 overlong) chmod 600 l/config/crew-claude-agent; python3 -c 'print("a"*129)' > l/config/crew-claude-agent; run_spawn invalid-overlong "$PWD/l/projects/probe" --scout --harness claude ;;
 esac
 status=$?
 printf 'exit=%s\n' "$status"
 [ "$status" = 1 ] || exit 1
done
chmod 600 l/config/crew-claude-agent
printf 'crew mate\n' > l/config/crew-claude-agent
after=$(sha256sum l/state/ship-h.meta)
[ "$before" = "$after" ] || exit 1
printf 'Existing worker metadata unchanged; rejected scouts have no task records: '
for id in invalid-scout invalid-unreadable invalid-overlong; do [ ! -e "l/state/$id.meta" ] || exit 1; done
printf 'yes\n'
