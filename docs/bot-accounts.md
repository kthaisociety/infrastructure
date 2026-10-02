# Bot accounts and credentials

Every non-human identity used by the delivery pipeline: why it exists, exactly what it may do, where its
credentials are, how to rotate them, and what breaks when they're gone. Created by hand (GitHub has no
API to create accounts or download App keys; Dokploy only lets the owner set member permissions and
only the user itself create its API keys). The design is in [delivery-plan.md](delivery-plan.md),
"Bot accounts and credentials".

Rules for all of them:
- **Least privilege, explicit scope.** Nothing is installed on, or visible to, "all repositories".
  Adding an app means adding it to each identity's scope by hand
  ([app-delivery.md](app-delivery.md), "Adding a new app").
- **GitHub App private keys live only in their GitHub secret.** Not in 1Password: an org owner can
  generate a new key at any time, so a copy would only be another place to leak from. Client IDs and App
  IDs aren't secret and are listed here.
- **Credentials that can't be regenerated go in 1Password**: the Dokploy API keys (Dokploy can't make one
  for another user) and state passphrases.

## GitHub Apps

All three: owned by the `kthaisociety` org (Settings → Developer settings → GitHub Apps, i.e.
`https://github.com/organizations/kthaisociety/settings/apps`), webhook off, "only on this account",
no OAuth, no client secret.

### `kthais-release`
| | |
|---|---|
| App ID / Client ID | 5164696 / `Iv23li6i9JI6PjjqVXkQ` |
| Permissions | Contents, Pull requests, Issues: read and write (Metadata: read) |
| Installed on | the app repos that release (today: `onboarding-service`), "only select repositories" |
| Used by | `kthaisociety/workflows` `release.yml`: release-please opens and updates release PRs, tags `vX.Y.Z`, publishes the GitHub Release |
| Why not `GITHUB_TOKEN` | GitHub runs no workflows for events made with `GITHUB_TOKEN`, so its release PRs would never get their required checks |
| Secrets | org secrets `RELEASE_APP_CLIENT_ID`, `RELEASE_APP_PRIVATE_KEY`, visibility "selected repositories": the same app repos |
| If the key leaks | anyone with it can push branches, open PRs, create tags and Releases in those app repos (not push to their protected `main`). Rotate. |
| If it stops working | release PRs stop appearing or updating; nothing else breaks |

### `kthais-dispatch`
| | |
|---|---|
| App ID / Client ID | 5165751 / `Iv23liBdZidpY547mYgv` |
| Permissions | Actions: read and write (Metadata: read) |
| Installed on | `deployments` only |
| Used by | app repos, to start `deployments`' `deploy.yml` and wait for its result [step 12] |
| Secrets | org secrets `DISPATCH_APP_CLIENT_ID`, `DISPATCH_APP_PRIVATE_KEY`, visibility "selected repositories": the app repos that deploy |
| If the key leaks | anyone with it can request deploys of existing images (any project: `deploy.yml` can't tell callers apart; its checks still apply), and cancel or re-run runs in `deployments`. A re-run of an old apply does nothing: applies only run `main`'s current tip. Rotate. |
| If it stops working | deploy requests fail; deploying by a manual `release.yaml` PR still works |

### `kthais-deploy`
| | |
|---|---|
| App ID / Client ID | 5165860 / `Iv23liGSSHr3uMAEKOiv` |
| Permissions | Contents, Pull requests: read and write (Metadata: read) |
| Installed on | `deployments` only |
| Used by | `deployments`' own `deploy.yml`, to open and merge the `release.yaml` PRs [step 12] |
| Ruleset | the only bypass of `deployments`' "main: human review" ruleset (approval, code owners, threads, Greptile). Never of "main: checks (no bypass)" |
| Secrets | repo secrets in `deployments`: `DEPLOY_APP_CLIENT_ID`, `DEPLOY_APP_PRIVATE_KEY`. Never org secrets |
| If the key leaks | anyone with it can open and merge PRs in `deployments` without human review, still only passing every required check (`bot-scope` limits bot PRs to `projects/*/release.yaml`). Rotate at once. |
| If it stops working | automatic deploys stop at the PR step |

### Rotating an App's key
1. App's settings page → **Generate a private key** (the App can hold several at once).
2. Set it: `gh secret set <NAME>_PRIVATE_KEY --org kthaisociety --visibility selected --repos <every repo> < new.pem`
   (org secrets; `--repos` replaces the list, so name all of them) or `-R kthaisociety/deployments`
   (`kthais-deploy`). Then `rm -P new.pem`.
3. Delete the old key on the App's page. It stops working at once.

## Dokploy users

### `ops+dokploy-terraform@kthais.com` (the `infrastructure` repo's user)
| | |
|---|---|
| Role | admin |
| Used by | `kthaisociety/infrastructure`'s `terraform/dokploy` (OpenBao's compose, Dokploy core) |
| Key | `DOKPLOY_API_KEY` in `infrastructure`'s `production` and `plan` environments; rate limiting off; copy in 1Password |

### `Deployments CI` (`ops+dokploy-deployments@kthais.com`)
| | |
|---|---|
| Role | **admin**. Started as a member (create projects, services, environments; API access), but members can't use vault providers (401 on `vaultProvider.testConnection`), and the custom role that could grant that needs a paid Dokploy license |
| Used by | `kthaisociety/deployments`' OpenTofu (projects, environments, vault providers, apps) |
| Key | `deployments-ci`, in `deployments`' `production` and `plan` environments as `DOKPLOY_API_KEY`; rate limiting off; copy in 1Password |
| If the key leaks | anything in Dokploy, like the `infrastructure` key: rotate at once. Its own user, so revoking it doesn't touch `infrastructure` |

Rotating a Dokploy key: sign in as the user, create a new key (rate limiting off), set it in both
environments, delete the old key, update 1Password.

## OpenBao logins (as code, in `terraform/openbao`)

| Role | Bound to | May |
|---|---|---|
| `infrastructure-ci` (`jwt` auth) | `infrastructure`'s `production` environment, immutable subject | everything (`terraform` policy) |
| `deployments-ci` (`jwt` auth) | `deployments`' `production` and `plan` environments, immutable subject | mint tokens through `dokploy-provider` only (`deployments` policy) |
| `infra-admin` (`oidc`, Google) | the listed kthais.com accounts | read and write app secrets; never `infrastructure/*` |

## State

| | `infrastructure` | `deployments` |
|---|---|---|
| Bucket, key | `kthais-tfstate`, `<root>/terraform.tfstate` | `kthais-tfstate`, `deployments/terraform.tfstate` |
| Credential | the tfstate instance's CI credential (`AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY`), hand-made | the same credential |
| Passphrase | `TF_VAR_state_passphrase`, in 1Password | its own `TF_VAR_STATE_PASSPHRASE`, in 1Password ("deployments OpenTofu state passphrase") |

The passphrases must differ: GleSYS credentials cover the whole instance, so the passphrase is what keeps
each repo's state unreadable to the other's CI. Losing a passphrase means losing that state.
