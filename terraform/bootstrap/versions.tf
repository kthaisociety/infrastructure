terraform {
  required_version = ">= 1.11"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
  }

  # Starts with local state. After the first apply, uncomment and run
  # `tofu init -migrate-state` to move the state into the bucket it created.
  # backend "gcs" {
  #   bucket = "kthais-infrastructure-tfstate"
  #   prefix = "bootstrap"
  # }
}

provider "google" {
  region = var.region
}
