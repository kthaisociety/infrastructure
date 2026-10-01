variable "project" {
  description = "Project name, as in its folder under terraform/projects/."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. production."
  type        = string
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
