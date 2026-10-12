# The Google Cloud projects KTHAIS runs on. OpenTofu creates them.
#
# Two kinds of project aren't here (docs/gcp.md):
# - The provisioner project, which CI signs in through. It's made by hand, and is the only one that is.
# - Projects from before this module. They stay as they are until nothing uses them, then they're deleted.
#
# Most of what these projects hold can't be in code: Google has no API for sign-in (OAuth) clients, and
# service account keys never go in state. Both are made by hand and listed in docs/gcp.md.

# A project has a name and an ID. The name is what the console shows. The ID (the keys below) is
# permanent and has to be unique across all of Google Cloud, so it's `kthais-` plus the name rather than
# the bare word (docs/gcp.md, "Why the IDs start with kthais-").

locals {
  # CI's two accounts in the hand-made project. The workflow that signs in as them passes the project's
  # ID and the accounts' names in, so none of the three is written here.
  ci_plan  = "serviceAccount:${var.plan_account}@${var.provisioner_project}.iam.gserviceaccount.com"
  ci_apply = "serviceAccount:${var.apply_account}@${var.provisioner_project}.iam.gserviceaccount.com"

  projects = {
    # The identity service's project: the one Google sign-in client every KTHAIS app goes through, and
    # the account that manages Google Workspace (identity.tf).
    kthais-identity = {
      name   = "identity"
      owners = ["user:sam@kthais.com", "user:vilhelm@kthais.com"]
      apis = [
        "admin.googleapis.com", # Admin SDK: Workspace accounts
        "iam.googleapis.com",   # for the service account in identity.tf
      ]
    }

    # Mattermost's sign-in client (chat.aisociety.se). Google is Mattermost's only way to sign in.
    kthais-mattermost = {
      name   = "mattermost"
      owners = ["user:sam@kthais.com", "user:vilhelm@kthais.com"]
      apis   = ["people.googleapis.com"] # Mattermost reads the profile of whoever signs in
    }
  }

  project_apis = merge([
    for id, p in local.projects : { for api in p.apis : "${id}/${api}" => { project = id, api = api } }
  ]...)
}

resource "google_project" "this" {
  for_each = local.projects

  project_id      = each.key
  name            = each.value.name
  org_id          = var.org_id
  billing_account = var.billing_account
  deletion_policy = "PREVENT"

  lifecycle {
    prevent_destroy = true
  }
}

resource "google_project_service" "this" {
  for_each = local.project_apis

  project            = google_project.this[each.value.project].project_id
  service            = each.value.api
  disable_on_destroy = false
}

# Owners are exactly the members listed above (`user:` or `group:`), plus CI. Someone made owner by hand
# is removed by the next apply. Other roles on a project aren't touched.
resource "google_project_iam_binding" "owner" {
  for_each = local.projects

  project = google_project.this[each.key].project_id
  role    = "roles/owner"
  members = concat(each.value.owners, [local.ci_apply])
}

# What `tofu plan` needs to read on a PR: the project, its APIs and service accounts, and who has access.
resource "google_project_iam_member" "plan" {
  for_each = {
    for pair in setproduct(keys(local.projects), ["roles/viewer", "roles/iam.securityReviewer"]) :
    "${pair[0]}/${pair[1]}" => { project = pair[0], role = pair[1] }
  }

  project = google_project.this[each.value.project].project_id
  role    = each.value.role
  member  = local.ci_plan
}
