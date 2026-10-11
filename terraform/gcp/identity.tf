# The account the identity service manages Google Workspace accounts with. It replaces
# onboarding-service-account in kthais-website-492616, a project from before this module.
#
# Two things about it stay by hand (docs/gcp.md, "Made by hand"):
# - Its key. A key made here would sit in state.
# - Its right to act as a Workspace admin, which is granted in the Workspace admin console.
resource "google_service_account" "workspace_admin" {
  project      = google_project.this["kthais-identity"].project_id
  account_id   = "workspace-admin"
  display_name = "Workspace admin (identity service)"

  depends_on = [google_project_service.this]
}
