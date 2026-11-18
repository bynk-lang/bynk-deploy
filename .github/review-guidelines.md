# Review guidelines for bynk-deploy

These are the maintainers' notes for reviewing a pull request here.
The repository is `bynk-deploy`, the action that deploys a Bynk project to
Cloudflare Workers with `bynk deploy`: it compiles every context, creates
resources, sets secrets, uploads the Workers, and can open a pull request for
a changed `bynk.deploy.lock` and smoke-test the result. It holds the
caller's Cloudflare token and their application's secrets.

It's a composite GitHub Action that other repositories pin by commit, so a
mistake here reaches every workflow that uses it, often in a run nobody is
watching. Skip what CI already enforces: the test workflow
(`.github/workflows/test.yml`) across its runners, and the canary at each new
Bynk release.

## What matters most

- **Untrusted input in shell.** An input or a value from the event reaches a
  script through `env:`, and the script quotes it. Flag a new `run:` that
  interpolates `${{ inputs.… }}`, `${{ github.event.… }}` or another
  step's output straight into the command line, where a crafted value
  becomes shell.
- **Pinned dependencies.** Every action this one uses is pinned to a full
  commit SHA, with its version in a comment for Dependabot. Downloaded tools
  are pinned to a version and verified where a checksum is published. Flag a
  floating tag, `@main`, or an unverified download.
- **Tokens and secrets.** A token is used only for the calls that need it,
  never echoed, and a secret value is masked (`::add-mask::`) before anything
  could print it. Flag a token or secret that reaches a log, an output, an
  artefact or a file left in the workspace.
- **Callers rely on the interface.** An input or output that's renamed or
  removed, a default that changes, or behaviour a workflow depends on that
  changes, is a breaking change: it needs a new major version, and the README
  says how to migrate. Flag one slipped into a minor or patch change.
- **Failing loudly.** A step that fails must fail the action, with a message
  that says what to do. `set -euo pipefail` (or its equivalent) stays on, and
  an error isn't swallowed by `|| true` without a reason in a comment.
- **Runners.** It runs on Linux and macOS. A change to a script must work on
  each, with the shells and tools they have (GNU and BSD `sed`, `sha256sum`
  and `shasum`, paths with spaces), or say why it doesn't need to.

## This action

- **Secrets.** Each value passed in `secrets` is masked before anything could
  print it, is written only where `bynk deploy` reads it, and is removed
  afterwards. Flag a path that logs, keeps or uploads one. The Cloudflare
  token is used only for the deploy.
- **Dry runs touch nothing.** `dry-run` and a pull request's plan need no
  credentials and change nothing in Cloudflare. Flag a change that makes a
  plan create, upload or set anything.
- **The lock file.** The action never commits. It reports a changed
  `bynk.deploy.lock` (`lock-changed`) and, with `lock-pr-token`, opens a pull
  request for it. Flag a change that pushes to the caller's branch.
- **Smoke tests** against a deployed target call only `GET` routes, unless
  the caller sets `smoke-unsafe`. Flag a change that makes a default smoke
  write.

## Tests

- A change of behaviour comes with a case in the test workflow, against the
  fixtures in `test/`: the success, and the failure it should report.
- Look for missing cases: an input left empty, an input that's invalid, a
  version that doesn't exist, a failing command in the middle, and each
  runner the change touches.

## Documentation and versions

- The README is the action's documentation. A new or changed input, output,
  default or behaviour updates its table or section in the same pull request,
  and the usage examples stay pinned by commit, with the version in a comment.
- `BYNK_VERSION` is moved by the org canary's pull request, once the tests
  pass at the new release. A hand-edited pin needs a reason.
- British English throughout: in comments, the README and messages the action
  prints ("behaviour", "organisation", "licence" as a noun).

## Severity here

- **Blocking:** a secret kept after the run, a dry run that changes
  Cloudflare, a push to the caller's branch, untrusted input reaching a shell,
  a token or secret exposed, an unpinned or unverified dependency, or a
  breaking change without a new major version.
- **Should fix:** a missing test case, a failure that's swallowed or
  explained badly, a runner left broken, or a README out of step with
  `action.yml`.
- **Nit:** wording, naming and small style points. Keep these few.
