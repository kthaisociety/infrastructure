output "provider_name" {
  description = "The Dokploy vault provider's name, used in references: $${{vault.<provider_name>.<path>:<KEY>}}."
  value       = local.name
}

output "path" {
  value = local.path
}

output "token" {
  value     = vault_token.this.client_token
  sensitive = true
}
