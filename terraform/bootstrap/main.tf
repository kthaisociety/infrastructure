# One-time foundation: the infrastructure project, the Terraform state bucket,
# and keyless GitHub Actions → GCP authentication. Applied by an org admin;
# everything after this runs in CI.

locals {
  repository = "${var.github_org}/${var.github_repo}"

  services = [
    "cloudkms.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "serviceusage.googleapis.com",
    "storage.googleapis.com",
    "sts.googleapis.com",
  ]
}

resource "google_project" "infrastructure" {
  project_id      = var.project_id
  name            = "KTHAIS Infrastructure"
  org_id          = var.org_id
  billing_account = var.billing_account
  deletion_policy = "PREVENT"
}

resource "google_project_service" "this" {
  for_each = toset(local.services)

  project            = google_project.infrastructure.project_id
  service            = each.value
  disable_on_destroy = false
}

# --- Terraform state ---------------------------------------------------------

resource "google_storage_bucket" "tfstate" {
  project                     = google_project.infrastructure.project_id
  name                        = "${var.project_id}-tfstate"
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      num_newer_versions = 50
    }
    action {
      type = "Delete"
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.this]
}

# --- GitHub Actions workload identity federation -----------------------------

resource "google_iam_workload_identity_pool" "github" {
  project                   = google_project.infrastructure.project_id
  workload_identity_pool_id = "github"
  display_name              = "GitHub Actions"

  depends_on = [google_project_service.this]
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = google_project.infrastructure.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = "github"
  display_name                       = "GitHub Actions OIDC"

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Only tokens from this one repo, in our org (by immutable ID), are accepted at all.
  attribute_condition = "assertion.repository_owner_id == '${var.github_org_id}' && assertion.repository == '${local.repository}'"

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }
}

# --- CI service accounts -----------------------------------------------------

# Read-only; used by `tofu plan` on pull requests from any branch.
resource "google_service_account" "terraform_plan" {
  project      = google_project.infrastructure.project_id
  account_id   = "terraform-plan"
  display_name = "Terraform plan (GitHub Actions, read-only)"
}

# Full control of this project; used by `tofu apply`, only from the protected environment.
resource "google_service_account" "terraform_apply" {
  project      = google_project.infrastructure.project_id
  account_id   = "terraform-apply"
  display_name = "Terraform apply (GitHub Actions)"
}

resource "google_service_account_iam_member" "plan_wif" {
  service_account_id = google_service_account.terraform_plan.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${local.repository}"
}

resource "google_service_account_iam_member" "apply_wif" {
  service_account_id = google_service_account.terraform_apply.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principal://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/subject/repo:${local.repository}:environment:${var.apply_environment}"
}

resource "google_project_iam_member" "plan" {
  for_each = toset(["roles/viewer", "roles/iam.securityReviewer"])

  project = google_project.infrastructure.project_id
  role    = each.value
  member  = google_service_account.terraform_plan.member
}

resource "google_project_iam_member" "apply" {
  project = google_project.infrastructure.project_id
  role    = "roles/owner"
  member  = google_service_account.terraform_apply.member
}

# Plan runs with -lock=false, so it only needs to read state.
resource "google_storage_bucket_iam_member" "tfstate_plan" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.terraform_plan.member
}

resource "google_storage_bucket_iam_member" "tfstate_apply" {
  bucket = google_storage_bucket.tfstate.name
  role   = "roles/storage.objectAdmin"
  member = google_service_account.terraform_apply.member
}
