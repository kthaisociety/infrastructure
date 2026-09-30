# Copy these into the GitHub repo's Actions variables (Settings → Secrets and variables → Actions → Variables).

output "GCP_WIF_PROVIDER" {
  value = google_iam_workload_identity_pool_provider.github.name
}

output "GCP_PLAN_SA" {
  value = google_service_account.terraform_plan.email
}

output "GCP_APPLY_SA" {
  value = google_service_account.terraform_apply.email
}

output "tfstate_bucket" {
  value = google_storage_bucket.tfstate.name
}
