#!/usr/bin/env bash
# bynk-deploy helper. Invoked by action.yml as `deploy.sh <phase>`, one phase
# per composite step. Inputs arrive as INPUT_* environment variables; nothing
# is interpolated into the shell by the workflow.
set -euo pipefail

phase="${1:?usage: deploy.sh <check|secrets|plan|deploy|lock|cleanup>}"

# The arguments every `bynk deploy` invocation shares, so the plan step and the
# deploy step can never disagree about what they are describing.
common_args() {
  args=()
  if [ -n "${INPUT_ENVIRONMENT:-}" ]; then
    args+=(--env "${INPUT_ENVIRONMENT}")
  fi
  if [ -n "${INPUT_CONTEXT:-}" ]; then
    args+=(--context "${INPUT_CONTEXT}")
  fi
  if [ -n "${SECRETS_FILE:-}" ]; then
    args+=(--secrets-file "${SECRETS_FILE}")
  fi
  if [ "${INPUT_FORCE_SECRETS:-false}" = "true" ]; then
    args+=(--force)
  fi
  if [ -n "${INPUT_EXTRA_ARGS:-}" ]; then
    local extra
    # Newlines become spaces first: `read` stops at the first one, which would
    # silently drop every line of a `|` block after the first.
    read -ra extra <<<"$(tr '\n' ' ' <<<"${INPUT_EXTRA_ARGS}")"
    if [ "${#extra[@]}" -gt 0 ]; then
      args+=(-- "${extra[@]}")
    fi
  fi
}

# Write a possibly multi-line value to $GITHUB_OUTPUT.
set_output() {
  local name="$1" value="$2" delim
  delim="EOF_$(od -An -N8 -tx1 /dev/urandom | tr -d ' \n')"
  {
    echo "${name}<<${delim}"
    echo "${value}"
    echo "${delim}"
  } >>"$GITHUB_OUTPUT"
}

case "$phase" in
  check)
    dir="${INPUT_WORKING_DIRECTORY:-.}"
    if [ ! -d "$dir" ]; then
      echo "::error::working-directory \`${dir}\` does not exist"
      exit 1
    fi
    if [ ! -f "${dir}/bynk.toml" ]; then
      echo "::error::no bynk.toml in \`${dir}\` — set working-directory to the Bynk project root"
      exit 1
    fi
    for pair in "dry-run=${INPUT_DRY_RUN:-false}" "force-secrets=${INPUT_FORCE_SECRETS:-false}"; do
      case "${pair#*=}" in
        true | false) ;;
        *)
          echo "::error::${pair%%=*} must be \`true\` or \`false\`, not \`${pair#*=}\`"
          exit 1
          ;;
      esac
    done
    case "${INPUT_PLAN_FORMAT:-json}" in
      json | text) ;;
      *)
        echo "::error::plan-format must be \`text\` or \`json\`, not \`${INPUT_PLAN_FORMAT}\`"
        exit 1
        ;;
    esac
    ;;

  secrets)
    # Mask every value before it can reach a log, parsing the same way the
    # driver does: skip blanks and `#` comments, allow an `export ` prefix,
    # split on the first `=`, trim, and strip one layer of matching quotes.
    while IFS= read -r raw || [ -n "$raw" ]; do
      line="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"$raw")"
      case "$line" in
        "" | "#"*) continue ;;
      esac
      line="${line#export }"
      case "$line" in
        *=*) ;;
        *) continue ;; # the driver reports the malformed line by number
      esac
      value="$(sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' <<<"${line#*=}")"
      if [ -n "$value" ]; then
        echo "::add-mask::${value}"
        if [ "${#value}" -lt 4 ]; then
          echo "::warning::secret \`${line%%=*}\` has a value under 4 characters; masking it hides every occurrence of that text in the log"
        fi
      fi
      if [ "${#value}" -ge 2 ]; then
        first="${value:0:1}" last="${value: -1}"
        if { [ "$first" = '"' ] || [ "$first" = "'" ]; } && [ "$first" = "$last" ]; then
          inner="${value:1:${#value}-2}"
          if [ -n "$inner" ]; then
            echo "::add-mask::${inner}"
          fi
        fi
      fi
    done <<<"${INPUT_SECRETS}"

    umask 077
    file="$(mktemp "${RUNNER_TEMP:-/tmp}/bynk-secrets.XXXXXX")"
    # Published first, so the cleanup step can find the file even if a later
    # line here fails.
    echo "path=${file}" >>"$GITHUB_OUTPUT"
    chmod 600 "$file"
    printf '%s\n' "${INPUT_SECRETS}" >"$file"
    ;;

  plan)
    # Always a dry run, always JSON: offline, side-effect free on Cloudflare,
    # and the source of the `plan` and `contexts` outputs for real deploys too.
    common_args
    plan_file="$(mktemp "${RUNNER_TEMP:-/tmp}/bynk-plan.XXXXXX")"
    echo "::group::bynk deploy --dry-run"
    trap 'rm -f "$plan_file"; echo "::endgroup::"' EXIT
    status=0
    bynk deploy --dry-run --format json ${args[@]+"${args[@]}"} >"$plan_file" || status=$?
    if [ "$status" -ne 0 ]; then
      cat "$plan_file"
      echo "::error::bynk deploy --dry-run failed (exit ${status}); see the log above"
      exit "$status"
    fi
    if [ "${INPUT_DRY_RUN}" = "true" ]; then
      if [ "${INPUT_PLAN_FORMAT:-json}" = "text" ]; then
        bynk deploy --dry-run --format short ${args[@]+"${args[@]}"}
      else
        cat "$plan_file"
      fi
    fi
    set_output plan "$(cat "$plan_file")"
    # Node rather than jq: this action always installs Node, not always jq.
    contexts="$(node -e 'console.log(JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).order.join(" "))' "$plan_file")"
    echo "contexts=${contexts}" >>"$GITHUB_OUTPUT"
    ;;

  deploy)
    common_args
    # An input wins; otherwise keep whatever the caller set in `env:`.
    export CLOUDFLARE_API_TOKEN="${INPUT_CLOUDFLARE_API_TOKEN:-${CLOUDFLARE_API_TOKEN:-}}"
    if [ -n "${INPUT_CLOUDFLARE_ACCOUNT_ID:-}" ]; then
      export CLOUDFLARE_ACCOUNT_ID="${INPUT_CLOUDFLARE_ACCOUNT_ID}"
    fi
    if [ -z "${CLOUDFLARE_API_TOKEN}" ]; then
      echo "::error::a real deploy needs a Cloudflare token: set cloudflare-api-token, or CLOUDFLARE_API_TOKEN in env (only a dry run can go without it)"
      exit 1
    fi
    echo "::group::bynk deploy"
    trap 'echo "::endgroup::"' EXIT
    status=0
    bynk deploy --yes ${args[@]+"${args[@]}"} || status=$?
    if [ "$status" -ne 0 ]; then
      echo "::error::bynk deploy failed (exit ${status}); contexts that landed stay deployed — fix the cause and re-run"
      exit "$status"
    fi
    ;;

  lock)
    # The action never commits. It only says when the committed ledger is
    # stale, which matters even after a failed run: a KV namespace created
    # before the failure is recorded only here.
    changed=false
    if [ -f bynk.toml ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
      if [ -n "$(git status --porcelain -- bynk.deploy.lock)" ]; then
        changed=true
        echo "::warning file=${INPUT_WORKING_DIRECTORY%/}/bynk.deploy.lock::bynk.deploy.lock changed during this deploy. Commit it: it holds the KV namespace ids and deployed-context records every later deploy relies on."
      fi
    fi
    echo "changed=${changed}" >>"$GITHUB_OUTPUT"
    ;;

  cleanup)
    if [ -n "${SECRETS_FILE:-}" ]; then
      rm -f "${SECRETS_FILE}"
    fi
    ;;

  *)
    echo "::error::deploy.sh: unknown phase \`${phase}\`"
    exit 2
    ;;
esac
