# infrastructure

Core KTHAIS infrastructure as code, with OpenTofu. See [docs/plan.md](docs/plan.md). Next milestone: OpenBao running and serving secrets to the first two apps, step by step in
[docs/openbao-deploy.md](docs/openbao-deploy.md). How apps will be built, released and deployed:
[docs/delivery-plan.md](docs/delivery-plan.md) (proposed). Root token or CI login trouble:
[docs/openbao-recovery.md](docs/openbao-recovery.md).

| Path | What | Status |
|---|---|---|
| `terraform/glesys/` | Object storage instances, credentials and buckets (state, OpenBao snapshots, backups) | Applied |
| `terraform/dokploy/` | Dokploy core (registry, secrets providers, backups, notifications), OpenBao (`bao.kthais.com`) and its snapshots, and every project | OpenBao only (applied, public) |
| `terraform/openbao/` | OpenBao config: KV mount, GitHub and Google logins, per project-environment policies and tokens | Applied |
| `terraform/projects/` | One folder per project; its `project.yaml` is read by both roots | `onboarding-service` (OpenBao side) |
| `terraform/modules/` | `project-secrets` (OpenBao side of a project) and `project` (Dokploy side, per project type) | `project-secrets` written; `project` not written yet |
| `.github/workflows/deploy.yml` | Deploys: app repos push images to GHCR and ask this repo to deploy; it commits the tag and applies | _Not written yet_ |
| `terraform/gcp/` | GCP projects, OAuth clients | _Later_ |

State is stored encrypted in GleSYS Object Storage. Pull requests run `tofu plan`; merges to `main` run
`tofu apply` from the `production` environment. Nothing is applied from a laptop.
