# infrastructure

Core KTHAIS infrastructure as code, with OpenTofu: the platform every app runs on. Apps themselves (their
Dokploy projects and the images they run) are in
[kthaisociety/deployments](https://github.com/kthaisociety/deployments).

**Docs**
- [docs/app-delivery.md](docs/app-delivery.md): how an app goes from a push to running on Dokploy, and
  how to add one. Start here.
- [docs/delivery-plan.md](docs/delivery-plan.md): the design behind it, and the decisions made.
- [docs/bot-accounts.md](docs/bot-accounts.md): every bot identity and credential, and how to rotate it.
- [docs/app-migration.md](docs/app-migration.md): moving an existing app off the Dokploy UI onto the
  pipeline, step by step: repo, bots, secrets, `deployments`, databases, data copy, switchover.
- [docs/onboarding-service-migration.md](docs/onboarding-service-migration.md): the first app moved.
- [docs/gcp.md](docs/gcp.md): Google Cloud: the three projects we're moving to, what's in code, what's
  made by hand, and how CI signs in.
- [docs/plan.md](docs/plan.md): the platform's plan (OpenBao, state, disaster recovery);
  [docs/openbao-deploy.md](docs/openbao-deploy.md): how OpenBao was deployed;
  [docs/openbao-recovery.md](docs/openbao-recovery.md): root token or CI login trouble.
- [docs/database-backups.md](docs/database-backups.md): the production databases' scheduled backups, and
  how to restore one.

| Path | What | Status |
|---|---|---|
| `terraform/glesys/` | Object storage instances, credentials and buckets (state, OpenBao snapshots, backups, apps' storage) | Applied |
| `terraform/dokploy/` | OpenBao on Dokploy (`bao.kthais.com`), Dokploy's database backups destination, later OpenBao's snapshots and Dokploy's other core settings | Applied (OpenBao) |
| `terraform/openbao/` | OpenBao config: KV mount, GitHub and Google logins, token roles, policies, `deployments-ci` | Applied |
| `terraform/openbao/projects.yaml` | Every project's OpenBao side, one line each (`my-app: {}`): its policies and empty secret paths | `onboarding-service` |
| `terraform/modules/project-secrets/` | One project environment's policy, empty path (and, for now, a provider token) | Applied |
| `terraform/gcp/` | The identity and Mattermost projects on Google Cloud: owners, APIs, service accounts. CI signs in through a third project, the only one made by hand ([docs/gcp.md](docs/gcp.md)) | Applied |

State is stored encrypted in GleSYS Object Storage. Pull requests run checks and, after a reviewer
approves, `tofu plan`; merges to `main` run `tofu apply` from the `production` environment. Nothing is
applied from a laptop.
