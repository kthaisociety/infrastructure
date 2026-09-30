# infrastructure

Core KTHAIS infrastructure as code, with OpenTofu. See [docs/plan.md](docs/plan.md). Next milestone: OpenBao running and serving secrets to the first two apps, step by step in
[docs/openbao-deploy.md](docs/openbao-deploy.md).

| Path | What | Status |
|---|---|---|
| `terraform/glesys/` | Object storage instances, credentials and buckets (state, OpenBao snapshots, backups) | Ready for first plan |
| `terraform/dokploy/` | Dokploy core (registry, secrets providers, backups, notifications), OpenBao (API at `bao.kthais.com`) and its snapshots, and one module per project under `projects/` | _Not written yet_ |
| `terraform/openbao/` | OpenBao config: KV mount, auth, per project-environment policies and tokens | _Not written yet_ |
| `.github/workflows/deploy.yml` | Deploys: app repos push images to GHCR and ask this repo to deploy; it commits the tag and applies | _Not written yet_ |
| `terraform/gcp/` | GCP projects, OAuth clients | _Later_ |

State is stored encrypted in GleSYS Object Storage. Pull requests run `tofu plan`; merges to `main` run
`tofu apply` from the `production` environment. Nothing is applied from a laptop.
