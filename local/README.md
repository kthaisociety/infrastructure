# local: KTHAIS's Dokploy platform, locally

A local copy of production's platform (Dokploy v0.30.8, Traefik, OpenBao 2.7.0), built by the **real**
OpenTofu of this repo and of `deployments`, through a local stand-in for their GitHub Actions. Add a line
to `projects.yaml` or a `project.yaml` in your checkout, run one command, and it exists locally, the same
way a merge to `main` makes it exist in production.

Nothing local is ever written into the repos: each run copies your working tree (uncommitted edits
included) like a CI checkout, adds the files in `overrides/`, and applies the copy.

## Quick start

You need Docker (Docker Desktop, or Docker Engine on Linux), `bash`, `curl`, `jq` and `openssl`, and a
checkout of [kthaisociety/deployments](https://github.com/kthaisociety/deployments) next to this one
(`../deployments`), or anywhere with `KTHAIS_DEPLOYMENTS=<path>`.

```sh
local/kthais-local up        # first run: ~5 min. Builds everything, then applies both repos
local/kthais-local status    # what's running, URLs, where the credentials are
```

To run it from anywhere: `ln -s "$PWD/local/kthais-local" ~/.local/bin/kthais-local`.

| What | Where |
|---|---|
| Dokploy | http://localhost:3000, sign in with `local/.state/dokploy-admin` |
| OpenBao | https://bao.localhost:8443 (accept Traefik's certificate), method **Token**, `jq -r .root_token local/.state/openbao-init.json` |
| An app's domain | http://`<host>`.localhost:8080, for a domain with `https: false` |

Windows browsers resolve `*.localhost` to this machine. WSL doesn't, but `curl` does on its own.

## Adding a project, locally

The same steps as `deployments/README.md`, "Adding a project":

1. `terraform/openbao/projects.yaml`: `my-app: {}`.
2. In `deployments`: `projects/my-app/project.yaml` (from `docs/project.template.yaml`), its
   `release.yaml` with every environment `null`, and `my-app` in `deploy.yml`'s project options.
   For a domain to reach locally, use `my-app.localhost: {port: <port>, https: false}`.
3. `kthais-local apply`: the PR checks of both repos, then this repo's apply (policies, empty secret
   paths) and deployments' (Dokploy project, environments, vault providers, apps, domains; not deployed).
4. Secrets: `kthais-local bao kv put -mount=secret my-app/staging KEY=value` (shared ones:
   `shared/staging`).
5. `kthais-local deploy my-app staging sha-<7>` (or `X.Y.Z`): deploy.yml's own validation, then the
   apply. Rolling back is the same with an older tag.

Removing a project goes the other way round. First remove it from `deployments` and run
`kthais-local apply deployments`, then remove its line from `projects.yaml` and run
`kthais-local apply infrastructure`. In the other order, the project's OpenBao policies go first, and
deployments' apply can lose access to what it has to delete there (database credentials: a 403).

A project with databases can't be removed by deleting lines: deployments refuses to delete data
(`prevent_destroy`, its `docs/project-yaml.md`). Locally, start over instead: `kthais-local destroy`, then
`up`. OpenBao keeps a removed project's secret paths, as in production. Delete them by hand:
`kthais-local bao kv metadata delete -mount=secret my-app/staging`.

## Commands

| Command | Does |
|---|---|
| `up` | Starts everything; the first run builds it all. Safe to repeat |
| `apply [infrastructure\|deployments\|all]` | What a merge to `main` runs: the checks, then `tofu apply` |
| `plan [infrastructure\|deployments]` | The checks and a plan, applying nothing |
| `deploy <project> <env> <tag>` | `deploy.yml`, with the line recorded in `.state/releases/` |
| `bao <args>` | The OpenBao CLI in its container, as root |
| `tofu <root> <args>` | Any tofu command in `infrastructure/dokploy`, `infrastructure/openbao` or `deployments` |
| `stop`, `start` | Stop or start the server, keeping everything (it also restarts with Docker Desktop) |
| `destroy` | Deletes the server, its volumes and `.state` (asks first) |

## How it maps to production

| Production | Here |
|---|---|
| The Synapse VPS | `kthais-dokploy`: one privileged Docker-in-Docker container (Docker 29.8.1, as production), its own swarm. `compose.yaml` |
| Dokploy's installer | `host/install-dokploy.sh`: the installer's steps (it refuses to run in a container), production's versions. Dokploy and its Postgres use DNS round-robin instead of a virtual IP, which some nested-Docker hosts can't route |
| GitHub Actions runners | `runner/`: Python 3.12, OpenTofu 1.12.6, yq, on the server's `dokploy-network` |
| The workflows' checks | Run from the workflow files themselves (`jobs/lib.sh`, `run_job_steps`); PR-only steps skipped; this repo's `projects.yaml` read from your checkout instead of GitHub's `main` |
| GitHub OIDC tokens for OpenBao | A local signer (`.state/jwt`) that local OpenBao's `jwt` login trusts instead. The `infrastructure-ci` and `deployments-ci` roles are unchanged, and the tokens carry the same subjects |
| State on GleSYS S3 | Local files in `.state/tofu`, encrypted the same way, with one local passphrase per repo |
| `terraform/glesys` | `mock/glesys`: only the outputs other roots read, with a placeholder key for OpenBao's snapshots. `terraform/gcp`: skipped |
| `bao.kthais.com` | `bao.localhost` (`https://bao.localhost:8443`); its http redirect drops the port |
| `release.yaml` on `main` | `.state/releases/<project>.yaml`: an environment not listed there is `null` |
| `deploy.yml` commits to `main` | Writes that local line. Its production check reads GitHub's public API anonymously |
| Two Dokploy admins (Terraform CI, Deployments CI) | One owner and one API key, rate limiting off |
| OpenBao: 3 recovery keys, root revoked, Google sign-in, userpass admins | 1 recovery key, root token kept, Google sign-in configured with a placeholder client, no userpass users |

## Files

```
kthais-local        the CLI
compose.yaml        the server container
host/               run on the server (install-dokploy.sh)
runner/             the CI runner image (and a `gh api` stand-in that never holds a token)
jobs/               the jobs, run in the runner: infrastructure, deployments, deploy, tofu
overrides/          merged into each root (*_override.tf): local endpoints, backends, the local signer
mock/glesys/        terraform/glesys's stand-in
.state/             generated, private, git-ignored: keys, credentials, tofu state, release lines, caches
```

The local pipeline copies this repo without `local/`, so none of it reaches the roots it applies.

## Known behaviour

- **Run on WSL2 with Docker Desktop.** Not yet on macOS. The images and the runner are built for both
  amd64 and arm64, and the setup has the Dokploy provider's two workarounds for nested Docker (DNS
  round-robin; retrying sign-in until Dokploy's auth is ready), but nobody has run it on a Mac yet.
- **The first `terraform/openbao` apply on a brand-new OpenBao fails** with "Upgrading from
  non-versioned to versioned data": its writes come right after `vault_mount.secret` is created. `up`
  expects it and applies once more, only for that error. Production would hit the same thing when
  rebuilding OpenBao from scratch.
- Changing a secret in OpenBao doesn't redeploy an app here either. Deploy again, or use Redeploy in
  Dokploy's UI. That UI action is fine locally; in production, changes go through the repo.
- A domain with `https: true` (the default) gets a Traefik route, but no certificate here. Use
  `https: false` with a `.localhost` host locally.
- One local platform per machine: the server's name (`kthais-dokploy`), its ports and its Docker volumes
  are fixed.
