# infrastructure

Core KTHAIS infrastructure as code.

| Path | What | Applied by |
|---|---|---|
| `terraform/bootstrap/` | `kthais-infrastructure` GCP project, Terraform state bucket, GitHub Actions → GCP federation | An org admin, once ([docs/bootstrap.md](docs/bootstrap.md)) |
| `terraform/gcp/` | KMS key for OpenBao auto-unseal, OpenBao snapshot bucket, their service accounts | GitHub Actions |
| `dokploy-core/openbao/` | OpenBao compose file and config, deployed by `terraform/dokploy` | _Not written yet_ |
| `terraform/openbao/` | OpenBao config: KV mount, auth, policies | _Not written yet_ |
| `terraform/dokploy/` | Dokploy core (registry, secrets provider, backups, notifications), OpenBao's deployment, and one module per project under `projects/` | _Not written yet_ |

CI authenticates to GCP with workload identity federation, so no service account keys are stored in GitHub.
Pull requests run `tofu plan` as a read-only service account. Merges to `main` run
`tofu apply` as a service account that only jobs in the `production` environment can use.
