#!/usr/bin/env bash
# Runs `deploy.sh check` and `deploy.sh smoke` with a stub `bynk` that records
# each call, and checks what the smoke would run. A real smoke needs a deploy.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
deploy="$here/../../scripts/deploy.sh"
failed=0
fail() { echo "::error::smoke: $*"; failed=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project"
printf '[project]\n' >"$tmp/project/bynk.toml"
# Answers `test --help` with or without --smoke (STUB_SMOKE), and fails the
# run itself when STUB_STATUS says so. tsc stands in for the runner.
cat >"$tmp/bin/bynk" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "test --help" ]; then
  echo "      --against <TARGET>"
  [ "$STUB_SMOKE" = 1 ] && echo "      --smoke"
  exit 0
fi
echo "bynk $*" >>"$STUB_LOG"
exit "${STUB_STATUS:-0}"
STUB
printf '#!/bin/sh\n' >"$tmp/bin/tsc"
chmod +x "$tmp/bin/bynk" "$tmp/bin/tsc"

# <phase> [VAR=value...]: runs the phase in the project, sets STATUS and LOG.
run() {
  local phase="$1"; shift
  : >"$tmp/log"
  STATUS=0
  (
    cd "$tmp/project"
    env PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_SMOKE=1 GITHUB_OUTPUT=/dev/null \
      INPUT_WORKING_DIRECTORY=. "$@" bash "$deploy" "$phase" >/dev/null
  ) || STATUS=$?
  LOG="$(cat "$tmp/log")"
}

run smoke INPUT_ENVIRONMENT=staging
[ "$STATUS" = 0 ] || fail "the environment as target: exited $STATUS"
[ "$LOG" = "bynk test --smoke --against staging" ] || fail "the environment as target ran: $LOG"

run smoke INPUT_ENVIRONMENT=staging INPUT_SMOKE_TARGET=preview INPUT_SMOKE_UNSAFE=true
[ "$LOG" = "bynk test --smoke --against preview --smoke-unsafe" ] || fail "smoke-target and smoke-unsafe ran: $LOG"

run smoke INPUT_SMOKE_TARGET=preview STUB_STATUS=3
[ "$STATUS" = 3 ] || fail "a failing smoke exited $STATUS, not 3"

run smoke INPUT_SMOKE_TARGET=preview STUB_SMOKE=0
[ "$STATUS" != 0 ] || fail "a Bynk without --smoke was not refused"
[ -z "$LOG" ] || fail "a Bynk without --smoke still ran: $LOG"

run plan INPUT_SMOKE=true INPUT_DRY_RUN=false STUB_SMOKE=0
[ "$STATUS" != 0 ] || fail "the plan step let a deploy go ahead that it can't smoke"
[ -z "$LOG" ] || fail "the plan step ran bynk before refusing: $LOG"

run check INPUT_SMOKE=true
[ "$STATUS" != 0 ] || fail "smoke with no target was not refused"
run check INPUT_SMOKE=true INPUT_ENVIRONMENT=staging
[ "$STATUS" = 0 ] || fail "smoke with an environment was refused"
run check INPUT_SMOKE=yes INPUT_ENVIRONMENT=staging
[ "$STATUS" != 0 ] || fail "smoke: yes was not refused"
run check INPUT_SMOKE_UNSAFE=True
[ "$STATUS" != 0 ] || fail "smoke-unsafe: True was not refused"

if [ "$failed" = 0 ]; then echo "smoke: all scenarios passed"; fi
exit "$failed"
