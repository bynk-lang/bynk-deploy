#!/usr/bin/env bash
# Runs `deploy.sh check`, `plan` and `revert` with a stub `bynk`, and checks
# what the revert would run and how it reports a refusal.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
deploy="$here/../../scripts/deploy.sh"
failed=0
fail() { echo "::error::revert: $*"; failed=1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project"
printf '[project]\n' >"$tmp/project/bynk.toml"
# STUB_REVERT=0 makes `revert --help` fail, as an older Bynk would. STUB_STATUS
# fails the revert itself, printing STUB_MSG.
cat >"$tmp/bin/bynk" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "test --help" ]; then echo "      --smoke"; exit 0; fi
if [ "$*" = "revert --help" ]; then [ "${STUB_REVERT:-1}" = 1 ]; exit $?; fi
echo "bynk $*" >>"$STUB_LOG"
if [ -n "${STUB_MSG:-}" ]; then echo "$STUB_MSG"; fi
exit "${STUB_STATUS:-0}"
STUB
chmod +x "$tmp/bin/bynk"

# <phase> [VAR=value...]: sets STATUS, LOG and OUT (the step outputs).
run() {
  local phase="$1"; shift
  : >"$tmp/log"; : >"$tmp/out"
  STATUS=0
  (
    cd "$tmp/project"
    env -u CLOUDFLARE_API_TOKEN PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" GITHUB_OUTPUT="$tmp/out" \
      INPUT_WORKING_DIRECTORY=. "$@" bash "$deploy" "$phase" >/dev/null
  ) || STATUS=$?
  LOG="$(cat "$tmp/log")"
  OUT="$(cat "$tmp/out")"
}

run revert INPUT_ENVIRONMENT=staging INPUT_CLOUDFLARE_API_TOKEN=t
[ "$STATUS" = 0 ] || fail "a successful revert exited $STATUS"
[ "$LOG" = "bynk revert --yes --env staging" ] || fail "the revert ran: $LOG"
grep -q '^reverted<<' "$tmp/out" && grep -q '^true$' "$tmp/out" || fail "reverted was not true: $OUT"

run revert INPUT_ENVIRONMENT=staging INPUT_CONTEXT=shop-orders INPUT_CLOUDFLARE_API_TOKEN=t
[ "$LOG" = "bynk revert --yes --env staging --context shop-orders" ] || fail "context revert ran: $LOG"

run revert INPUT_ENVIRONMENT=staging INPUT_CLOUDFLARE_API_TOKEN=t STUB_STATUS=1 \
  STUB_MSG="refused: D1 migrations applied since the target"
[ "$STATUS" = 1 ] || fail "a refused revert exited $STATUS, not 1"
grep -q '^false$' "$tmp/out" || fail "reverted was not false after a refusal: $OUT"
grep -q 'refused: D1 migrations applied since the target' "$tmp/out" || fail "the refusal reason was not reported: $OUT"

run revert INPUT_ENVIRONMENT=staging INPUT_CLOUDFLARE_API_TOKEN=t STUB_STATUS=1 STUB_MSG="::set-output x"
grep -q '^set-output x$' "$tmp/out" || fail "a leading :: was not defanged: $OUT"

run revert INPUT_ENVIRONMENT=staging
[ "$STATUS" != 0 ] || fail "a revert with no token was not refused"
[ -z "$LOG" ] || fail "a revert with no token still ran bynk: $LOG"

run plan INPUT_SMOKE=true INPUT_REVERT_ON_SMOKE_FAILURE=true INPUT_DRY_RUN=false STUB_REVERT=0
[ "$STATUS" != 0 ] || fail "the plan step let a deploy go ahead that it can't revert"
[ -z "$LOG" ] || fail "the plan step ran bynk before refusing: $LOG"

run check INPUT_REVERT_ON_SMOKE_FAILURE=true INPUT_ENVIRONMENT=staging
[ "$STATUS" != 0 ] || fail "revert without smoke was not refused"
run check INPUT_REVERT_ON_SMOKE_FAILURE=true INPUT_SMOKE=true INPUT_ENVIRONMENT=staging
[ "$STATUS" = 0 ] || fail "revert with smoke was refused"
run check INPUT_REVERT_ON_SMOKE_FAILURE=yes INPUT_SMOKE=true INPUT_ENVIRONMENT=staging
[ "$STATUS" != 0 ] || fail "revert-on-smoke-failure: yes was not refused"

if [ "$failed" = 0 ]; then echo "revert: all scenarios passed"; fi
exit "$failed"
