# A sign-in client's ID starts with the number of the project that holds it.
output "project_numbers" {
  value = { for id, project in google_project.this : id => project.number }
}

# What a Workspace super admin enters under domain-wide delegation.
output "workspace_admin_client_id" {
  value = google_service_account.workspace_admin.unique_id
}
