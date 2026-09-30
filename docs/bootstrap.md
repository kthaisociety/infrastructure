# Bootstrap

Everything in this repo is applied by GitHub Actions, except `terraform/bootstrap/`.
That stack creates the identity CI uses, so it has to be applied once by an org admin.
Run it from [Cloud Shell](https://shell.cloud.google.com) so it doesn't run on anyone's machine.

## 1. Prerequisites (org admin)

- A billing account for `kthais-infrastructure`. KMS and Cloud Storage don't work without one.
  Expected cost is well under $1/month.
- Roles: `roles/resourcemanager.projectCreator` on the org and `roles/billing.user` on the billing account.

## 2. Apply `terraform/bootstrap`

Cloud Shell doesn't include OpenTofu, so install it first:

```sh
curl -fsSL https://get.opentofu.org/install-opentofu.sh | sh -s -- --install-method deb
```

Then:

```sh
git clone https://github.com/kthaisociety/infrastructure && cd infrastructure/terraform/bootstrap
echo 'billing_account = "XXXXXX-XXXXXX-XXXXXX"' > terraform.tfvars
tofu init
tofu apply
```

Then move the state into the bucket it just created:

1. Uncomment the `backend "gcs"` block in `versions.tf`.
2. `tofu init -migrate-state`
3. Commit the change.

## 3. Configure the GitHub repo

- **Settings → Environments → New environment `production`**
  - Deployment branches: `main` only.
  - Required reviewers: optional. When set, every apply waits for approval.
- **Settings → Secrets and variables → Actions → Variables**: add `GCP_WIF_PROVIDER`,
  `GCP_PLAN_SA` and `GCP_APPLY_SA` from `tofu output`. None of them are secret.
- **Branch protection on `main`**: require a PR. Merging to `main` is what triggers applies.

From here on, changes to `terraform/gcp/` are planned on the PR and applied on merge.

## 4. OpenBao service account keys

Keys are created by hand so they never enter state. After `terraform/gcp` has been applied:

```sh
gcloud iam service-accounts keys create openbao-unseal.json.key \
  --iam-account=openbao-unseal@kthais-infrastructure.iam.gserviceaccount.com
gcloud iam service-accounts keys create openbao-backup.json.key \
  --iam-account=openbao-backup@kthais-infrastructure.iam.gserviceaccount.com
```

Store both in 1Password, then delete the local files.
