# bynk-deploy

Compile a Bynk project and deploy the generated Cloudflare Worker(s) with
[wrangler](https://developers.cloudflare.com/workers/wrangler/). Bynk emits one
Worker (with its own `wrangler.toml`) per `context` under `<output>/workers/`;
this action runs `wrangler deploy` in each.

## Usage

```yaml
name: Deploy
on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: bynk-lang/bynk-deploy@v1
        with:
          version: 0.107.0
          source: src
          cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
          cloudflare-account-id: ${{ secrets.CLOUDFLARE_ACCOUNT_ID }}
```

Preview without shipping:

```yaml
- uses: bynk-lang/bynk-deploy@v1
  with:
    dry-run: "true"
    cloudflare-api-token: ${{ secrets.CLOUDFLARE_API_TOKEN }}
```

## Inputs

| Input                   | Default       | Description |
| ----------------------- | ------------- | ----------- |
| `version`               | `latest`      | Bynk version (forwarded to setup-bynk). |
| `repository`            | `accuser/bynk`| Release repository. |
| `working-directory`     | `.`           | Project root. |
| `source`                | `src`         | Path passed to `bynkc compile`. |
| `output`                | `.bynk/build` | Build dir; Workers land under `<output>/workers/`. |
| `workers`               | `""`          | Space-separated worker names to deploy (empty = all). |
| `environment`           | `""`          | wrangler `--env` value. |
| `dry-run`               | `false`       | Use `wrangler deploy --dry-run`. |
| `node-version`          | `20`          | Node.js version for wrangler. |
| `wrangler-version`      | `latest`      | wrangler version run via `npx`. |
| `cloudflare-api-token`  | —             | **Required.** Cloudflare API token. |
| `cloudflare-account-id` | `""`          | Cloudflare account ID. |
| `github-token`          | `${{ github.token }}` | Token for setup-bynk. |

## Notes

- Provide the Cloudflare token as a repository/organisation **secret** — never
  inline it.
- The compile invocation mirrors `bynk dev` (`bynkc compile <source> --output
  <dir>`). If your project uses different flags, adjust `source`/`output`.
- Pin `actions/setup-node` to a commit SHA before publishing.

## License

Licensed under either of [MIT](LICENSE-MIT) or [Apache-2.0](LICENSE-APACHE) at
your option.
