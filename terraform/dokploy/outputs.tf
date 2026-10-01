# The infrastructure project's ids, for reference.

output "infrastructure" {
  value = {
    project_id     = dokploy_project.infrastructure.id
    environment_id = dokploy_project.infrastructure.production_environment_id
  }
}
