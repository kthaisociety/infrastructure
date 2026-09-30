# infrastructure

Core KTHAIS infrastructure as code, with OpenTofu. See [docs/plan.md](docs/plan.md).

| Path | What | Status |
|---|---|---|
| `terraform/glesys/` | Object storage instances, credentials and buckets (state, OpenBao snapshots, backups) | Ready for first plan |
| `terraform/dokploy/` | Dokploy core (registry, secrets provider, backups, notifications), OpenBao's deployment, and one module per project under `projects/` | _Not written yet_ |
| `dokploy-core/openbao/` | OpenBao compose file and config, deployed by `terraform/dokploy` | _Not written yet_ |
| `terraform/openbao/` | OpenBao config: KV mount, auth, per project-environment policies and tokens | _Not written yet_ |
| `terraform/gcp/` | GCP projects, OAuth clients | _Later_ |

State is stored encrypted in GleSYS Object Storage. Pull requests run `tofu plan`; merges to `main` run
`tofu apply` from the `production` environment. Nothing is applied from a laptop.
