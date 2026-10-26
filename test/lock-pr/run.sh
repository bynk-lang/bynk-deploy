#!/usr/bin/env bash
# Runs `deploy.sh lock-pr` against a throwaway repository with a stub `gh`
# that records each call, and checks what it would ask GitHub to do. No
# network: the stub answers from the STUB_* variables.
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
deploy="$here/../../scripts/deploy.sh"
failed=0
fail() { echo "::error::lock-pr: $*"; failed=1; }

# <name> <working-directory> <environment> <branch exists: 0|1> <open PR url or "">
scenario() {
  local name="$1" wd="$2" env="$3" exists="$4" open="$5"
  local tmp; tmp="$(mktemp -d)"
  mkdir -p "$tmp/bin" "$tmp/repo/$wd"
  cat >"$tmp/bin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >>"$STUB_LOG"
case "$*" in
  "api repos/o/r/git/ref/heads/"*) [ "$STUB_EXISTS" = 1 ] || exit 1; echo '{}' ;;
  "api repos/o/r/contents/"*"?ref="*) [ "$STUB_EXISTS" = 1 ] && echo oldsha || exit 1 ;;
  "pr list"*) echo "$STUB_OPEN" ;;
  "pr create"*) echo "https://github.com/o/r/pull/9" ;;
esac
STUB
  chmod +x "$tmp/bin/gh"
  (
    cd "$tmp/repo"
    git init -q && git config user.email t@t && git config user.name t
    printf '[project]\n' >"$wd/bynk.toml"
    printf 'a\n' >"$wd/bynk.deploy.lock"
    printf 's\n' >"$wd/bynk.schema.lock"
    git add -A && git commit -qm init
    printf 'b\n' >"$wd/bynk.deploy.lock"
  )
  : >"$tmp/log"; : >"$tmp/out"
  (
    cd "$tmp/repo/$wd"
    PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_EXISTS="$exists" STUB_OPEN="$open" \
    GH_TOKEN=t GITHUB_REPOSITORY=o/r GITHUB_REF_NAME=main GITHUB_REF_TYPE=branch \
    GITHUB_SHA=0123456789abcdef GITHUB_RUN_ID=42 GITHUB_OUTPUT="$tmp/out" \
    INPUT_WORKING_DIRECTORY="$wd" INPUT_ENVIRONMENT="$env" \
      bash "$deploy" lock-pr >/dev/null
  ) || fail "$name: exited $?"
  LOG="$(cat "$tmp/log")" OUT="$(cat "$tmp/out")"
  rm -rf "$tmp"
}
has()  { grep -qF -- "$2" <<<"$LOG" || fail "$1: no call matching: $2"; }
lacks() { ! grep -qF -- "$2" <<<"$LOG" || fail "$1: unexpected call: $2"; }

scenario "first lock PR" . "" 0 ""
has "first" "api -X POST repos/o/r/git/refs -f ref=refs/heads/bynk-deploy/lock -f sha=0123456789abcdef"
has "first" "api -X PUT repos/o/r/contents/bynk.deploy.lock -f message=Record the deploy in bynk.deploy.lock"
has "first" "-f branch=bynk-deploy/lock"
lacks "first" "contents/bynk.schema.lock -f"   # unchanged, so not proposed
lacks "first" "-f sha=oldsha"
has "first" "pr create --repo o/r --head bynk-deploy/lock --base main --title Record the deploy in bynk.deploy.lock"
grep -qx 'url=https://github.com/o/r/pull/9' <<<"$OUT" || fail "first: url output was '$OUT'"

scenario "an open lock PR is updated" . "" 1 "https://github.com/o/r/pull/7"
has "update" "api -X PATCH repos/o/r/git/refs/heads/bynk-deploy/lock -f sha=0123456789abcdef -F force=true"
has "update" "-f sha=oldsha"
lacks "update" "pr create"
grep -qx 'url=https://github.com/o/r/pull/7' <<<"$OUT" || fail "update: url output was '$OUT'"

scenario "a subdirectory and an environment" apps/web staging 0 ""
has "subdir" "refs/heads/bynk-deploy/lock-staging-apps-web"
has "subdir" "contents/apps/web/bynk.deploy.lock -f message=Record the deploy in apps/web/bynk.deploy.lock"
has "subdir" "--title Record the deploy in bynk.deploy.lock (staging) for apps/web"

if [ "$failed" = 0 ]; then echo "lock-pr: all scenarios passed"; fi
exit "$failed"
