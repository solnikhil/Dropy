#!/bin/zsh
# Own the desktop for the whole run, including failure cleanup. Preferences survive SIGKILL.
set -euo pipefail
repo_dir="${0:A:h:h:h}"
source "$repo_dir/Scripts/lib/device-session.zsh"
pgrep -xq Dropy && { print -u2 'Quit Dropy before a live benchmark; the suite will not close your app.'; exit 2; }
[[ -e "$HOME/Library/Application Support/Dropy/placement-journal.json" ]] && {
  print -u2 'Resolve the pending Dropy window-recovery journal before benchmarking.'; exit 2
}
device_session_begin benchmark-v2 || exit 2
export DROPY_BENCH_SESSION="$DROPY_DEVICE_SESSION"
mkdir -p "$repo_dir/.build/bench-suite"
export DROPY_BENCH_RESULT_POINTER="$repo_dir/.build/bench-suite/session-$$.result"
finalized=no
finish() {
  [[ "$finalized" == no ]] || return 0
  finalized=yes
  local restored=0
  device_session_end || restored=$?
  if [[ -f "$DROPY_BENCH_RESULT_POINTER" ]]; then
    local result_file="$(cat "$DROPY_BENCH_RESULT_POINTER")"
    rm "$DROPY_BENCH_RESULT_POINTER"
    bun "$repo_dir/Scripts/bench/suite.ts" finalize "$result_file" "$restored"
  else
    return "$restored"
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
bun "$repo_dir/Scripts/bench/suite.ts" run "$@"
finish
