# bynk-deploy

Deploy a Bynk project to Cloudflare Workers with the `bynk deploy` driver.

The action installs Bynk (through [setup-bynk](https://github.com/bynk-lang/setup-bynk))
and Node, then runs `bynk deploy --yes` from your project root. The driver does
the whole job:

- compiles every context;
- creates KV namespaces and records their ids in `bynk.deploy.lock`;
- creates queues before the upload;
- sets secrets: a missing declared actor `auth` secret fails the deploy, and a
  missing `Secrets.get("…")` name is a warning;
- deploys contexts in Service Binding order;
- refuses a `--context` push that would ship a contract skew
  (`bynk.deploy.contract_skew`);
- writes environment-scoped config for `--env`.

See [Deploy to Cloudflare](https://bynk-lang.org/book/guides/projects-build-and-deployment/deploy-to-cloudflare/)
for the full behaviour.

## Usage

```yaml
name: Deploy
on:
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v7
      - uses: bynk-lang/bynk-deploy@v2
        with:
          version: 0.313.0
          cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          cloudflare-account-id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

Preview the plan without touching Cloudflare. A dry run never authenticates,
so it needs no token:

```yaml
- uses: bynk-lang/bynk-deploy@v2
  id: plan
  with:
    version: 0.313.0
    dry-run: "true"
    plan-format: text
- env:
    PLAN: ${{ steps.plan.outputs.plan }}
  run: echo "$PLAN" | jq '.order'
```

Deploy to a named environment:

```yaml
- uses: bynk-lang/bynk-deploy@v2
  with:
    version: 0.313.0
    environment: staging
    cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

Re-push one context in a topology that is already live:

```yaml
- uses: bynk-lang/bynk-deploy@v2
  with:
    version: 0.313.0
    context: commerce.orders
    cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

`context` does **not** deploy that context's dependencies. If it binds to a
context that has never been deployed, the driver refuses rather than send an
upload Cloudflare would reject. Bring a new topology up with a whole-project
deploy first.

## Secrets

Put the values in repository or environment secrets and pass them as dotenv
lines in `secrets`:

```yaml
- uses: bynk-lang/bynk-deploy@v2
  with:
    version: 0.313.0
    cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
    cloudflare-account-id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
    secrets: |
      AUTH_JWT_SECRET=${{ secrets.AUTH_JWT_SECRET }}
      STRIPE_KEY=${{ secrets.STRIPE_KEY }}
```

The action:

1. masks each value with `::add-mask::`;
2. writes the content to a temporary file with mode 600;
3. passes it as `--secrets-file`;
4. deletes the file at the end of the run, even after a failure.

The action itself never echoes the content. GitHub, though, prints each step's
`with:` inputs and `env:` in the log header before any `::add-mask::` can run.
Values that come straight from `${{ secrets.* }}` are already masked by GitHub,
so they stay hidden. **A literal value, or one built from a secret (a substring,
say), appears in the log.** Only pass values that come directly from
`secrets.*`.

Every value is still masked as well. A value shorter than 4 characters gets a
warning, because masking it hides every occurrence of that text in the log.

Dotenv rules are the driver's: `#` comments, blank lines, an optional `export `
prefix, and one layer of matching quotes.

The driver also reads a value from the environment for any name it already
knows (a declared or read secret), so `env:` on the step works for those. It
never scans the environment for names.

Things to know:

- **Every name in `secrets` is set on every context in the run.** Nothing says
  which contexts read a `Secrets.get` name, so the driver sets it on all of
  them. The plan lists each one as `(supplied)`.
- **An unset declared secret fails the deploy**, naming it. In CI there is no
  prompt to fall back to.
- **Secrets are set only if absent.** Cloudflare doesn't return secret values,
  so the driver can't tell whether yours changed. Set `force-secrets: "true"`
  after rotating a value.

## The lock file

`bynk.deploy.lock` sits beside `bynk.toml` and **must be committed**. It holds
the KV namespace ids Cloudflare generated, the contexts that have been deployed,
and the queues created, with one section per environment. It holds no secrets.

The action never commits. After a real deploy (successful or not) it runs
`git status --porcelain -- bynk.deploy.lock`. If the file changed, the action
emits a warning and sets the `lock-changed` output to `"true"`. Commit the
change.

**CI cannot bootstrap a new KV namespace.** A namespace id is minted by
Cloudflare, and a CI job that creates one but can't commit it leaves an orphan
nobody can find again. So when `CI` is set (GitHub sets it), a context whose KV
namespace isn't recorded in the lock file fails with:

```
bynk: KV namespace for `<worker>` is unrecorded; provision locally first and commit bynk.deploy.lock
```

Run the first deploy locally (`bynk deploy`), commit `bynk.deploy.lock`, then let
CI push later builds. The restriction is KV's alone. CI can create queues,
declare Durable Objects and set secrets, because all of those are identified by
names that come from your source.

## Inputs

| Input | Default | Description |
| --- | --- | --- |
| `version` | `latest` | Bynk version (forwarded to setup-bynk). Pin it for reproducible deploys. |
| `repository` | `accuser/bynk` | Release repository. |
| `working-directory` | `.` | Project root. Must contain `bynk.toml`. |
| `context` | `""` | `--context`: deploy this one context, by dotted or worker name. Empty deploys every context in order. |
| `environment` | `""` | `--env`. Empty is the driver's `default` environment. |
| `dry-run` | `false` | `--dry-run`: print the plan, change nothing. Must be `true` or `false`. |
| `plan-format` | `json` | How a dry run prints the plan in the log: `text` (the driver's `short`) or `json`. The `plan` output is JSON either way. |
| `secrets` | `""` | Dotenv `NAME=value` lines, passed as `--secrets-file`. See [Secrets](#secrets). |
| `force-secrets` | `false` | `--force`: overwrite secrets that are already set. Must be `true` or `false`. |
| `extra-args` | `""` | Arguments for `wrangler deploy`, passed after `--`. Split on whitespace (newlines included, so a `|` block works), with no shell quoting. The driver rejects `--env` or `--environment` here; use `environment`. |
| `node-version` | `22` | Node.js for Wrangler. The driver requires 22 or later. |
| `cloudflare-api-token` | `""` | Cloudflare API token, set as `CLOUDFLARE_API_TOKEN`. A real deploy needs this or `CLOUDFLARE_API_TOKEN` in the step's `env:`; the input wins if both are set. A dry run needs neither. |
| `cloudflare-account-id` | `""` | Cloudflare account ID, set as `CLOUDFLARE_ACCOUNT_ID`. |
| `github-token` | `${{ github.token }}` | Token for setup-bynk. |

## Outputs

| Output | Description |
| --- | --- |
| `plan` | The plan as JSON (`bynk deploy --dry-run --format json`), including `order`, each context's `kv`, `queues`, `durable_objects` (from Bynk 0.313.0; `migration` before it), `secrets` (with `origin`: `declared`, `read` or `supplied`), `secrets_complete` and `binds_to`, and any `orphans`. Set for real deploys too, from a dry run that precedes them. |
| `contexts` | Space-separated worker names in deploy order, such as `shop-payment shop-orders`. The driver pushes every context in the plan (each plan action is `deploy` or `redeploy`; none is skipped), so after a successful real deploy these are the contexts deployed. |
| `lock-changed` | `"true"` if a real deploy changed `bynk.deploy.lock`, otherwise `"false"`. Always `"false"` for a dry run. |

The driver doesn't report Worker URLs. Wrangler prints them in the log.

## How a run works

1. Check that `working-directory` contains `bynk.toml`.
2. Install Bynk and Node.
3. Write the secrets file, if `secrets` is set.
4. **Plan:** `bynk deploy --dry-run --format json …`. This is offline and fills
   the `plan` and `contexts` outputs. It also catches bad input (a malformed
   secrets line, a `--context` whose dependency was never deployed, `--env`
   after `--`) before anything touches Cloudflare.
5. **Deploy** (unless `dry-run`): `bynk deploy --yes …`.
6. Check `bynk.deploy.lock` and warn if it changed (unless `dry-run`).
7. Delete the secrets file.

Every step that shells out to the driver runs inside a log group. A failed
multi-context deploy is resumable, not transactional: contexts that landed stay
deployed and recorded, so fix the cause and re-run.

### Choosing a Wrangler version

The driver has no flag for this. It uses the first Wrangler it finds in this
order:

1. `node_modules/.bin/wrangler` in the project;
2. `wrangler` on `PATH`;
3. `npx --yes wrangler@4`.

To pin a version, add `wrangler` to the project's `devDependencies` and run
`npm ci` in `working-directory` before this action. From Bynk 0.313.0, a
project with agents needs Wrangler **4.107.0 or later**: agents are declared in
Wrangler's `exports` table as SQLite-backed Durable Objects, which also lets
them deploy on the Workers Free plan.

### Compile errors

The driver prints compile errors in its multi-line format, which the
`bynk-ci` problem matcher can't parse, so this action doesn't install one. Run
[bynk-ci](https://github.com/bynk-lang/bynk-ci) before deploying to get inline
annotations.

## Migrating from v1

v1 ran `bynkc compile` and then plain `wrangler deploy` in each Worker
directory. That skipped KV provisioning (KV ids stayed placeholders), queue
creation, secrets, deploy ordering and the contract-skew check. v2 hands all of
that to `bynk deploy`.

| v1 input | v2 |
| --- | --- |
| `source` | **Removed.** The driver compiles the project rooted at `bynk.toml`. |
| `output` | **Removed.** The driver builds into `.bynk/deploy/` and has no option to change it. |
| `workers` | **Replaced by `context`**, which takes one context, not a list, and doesn't deploy its dependencies. |
| `wrangler-version` | **Removed.** The driver has no flag for it; see [Choosing a Wrangler version](#choosing-a-wrangler-version). |
| `node-version` | Kept. **The default is now `22`**, the driver's minimum (it was `20`). |
| `cloudflare-api-token` | Kept. No longer required for a dry run. |
| `environment`, `dry-run`, `version`, `repository`, `working-directory`, `cloudflare-account-id`, `github-token` | Unchanged. |

New inputs: `secrets`, `force-secrets`, `extra-args`, `plan-format`.
New outputs: `plan`, `contexts`, `lock-changed`.

Before switching an existing project:

- If it has a KV namespace, run `bynk deploy` locally once and commit
  `bynk.deploy.lock`. Otherwise the CI deploy will refuse, because v1 never
  recorded an id.
- If it declares actor `auth` secrets, supply them through `secrets` unless
  they are already set on Cloudflare. v1 never set them; v2 fails the deploy
  when a declared secret is neither supplied nor already set.

## Notes

- Keep the Cloudflare token in a repository or organisation **secret**. Never
  inline it.
- `actions/setup-node` is pinned to a commit SHA.
- `bynk deploy` also writes `bynk.schema.lock` when it compiles. Commit that
  file too.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE) at
your option.
