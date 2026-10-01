variable "project" {
  description = "Project name, as in its folder under terraform/projects/."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.project))
    error_message = "Project names are lowercase letters, digits and single hyphens."
  }
}

variable "environment" {
  description = "Environment name, e.g. production."
  type        = string
  # No hyphens: names are joined as <project>-<environment> (policy, provider), so the last hyphen must
  # always be the separator. Otherwise onboarding-service/production and onboarding/service-production
  # would get the same policy and provider.
  validation {
    condition     = can(regex("^[a-z0-9]+$", var.environment))
    error_message = "Environment names are lowercase letters and digits only, no hyphens."
  }
}

variable "shared" {
  description = "Names of shared secrets this project reads, at secret/shared/<name>/<environment>."
  type        = list(string)
  default     = []
}

variable "mount" {
  description = "The KV v2 mount. Passed from vault_mount.secret so the mount exists first."
  type        = string
}

variable "token_role" {
  description = "The token role provider tokens are made from (dokploy-provider)."
  type        = string
}

variable "create_path" {
  description = "Create the empty <project>/<environment> path. False when OpenTofu writes the path itself."
  type        = bool
  default     = true
}
