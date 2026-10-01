# Read by terraform/openbao through terraform_remote_state, for the infrastructure project's vault provider.

output "infrastructure" {
  value = {
    project_id     = dokploy_project.infrastructure.id
    environment_id = dokploy_project.infrastructure.production_environment_id
  }
}
