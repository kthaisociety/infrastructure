variable "config" {
  description = "The decoded project.yaml."
  type        = any
}

variable "provider_tokens" {
  description = "Per environment: the vault provider's OpenBao token, from terraform/openbao's dokploy_providers output."
  type        = map(string)
  sensitive   = true
}

variable "github_id" {
  description = "Id of the GitHub App registered in Dokploy, for building from the project's repo."
  type        = string
}
