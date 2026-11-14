# MLflow, experiment tracking for the research team (IT-36). Runbook: docs/mlflow.md.
# Not a kthaisociety/deployments project: we don't build or release MLflow, so it runs here as a compose,
# like OpenBao, and changes by PR. Production only.
#
#   postgres  run metadata. On the compose's own network only, so it needs no password (trust auth):
#             only the mlflow container can reach it. Never put it on dokploy-network. Backed up daily.
#   mlflow    the server, at https://mlflow.kthais.com. Artifacts go to its own GleSYS bucket through
#             the server (artifact proxying), so clients never hold the bucket's keys.
#
# NO SIGN-IN for now: anyone who can reach the address can read, write and delete runs and artifacts.
#
# The bucket's credentials are ${{vault…}} references in the compose's env, resolved by Dokploy at deploy
# time from secret/mlflow/production/storage (written by terraform/openbao, storage.tf, from `mlflow` in
# its projects.yaml). They never enter this state.

locals {
  mlflow_host = "mlflow.kthais.com"

  # Bump by PR, after a manual backup: a new MLflow can migrate the database (docs/mlflow.md).
  # -full has the Postgres and S3 drivers (psycopg2, boto3) that the plain image lacks.
  mlflow_image          = "ghcr.io/mlflow/mlflow:v3.18.0-full@sha256:a8459ca08b1e8a0dc287b4e226d4f2338f56052d7e2d333a4aa5891be0670919"
  mlflow_postgres_image = "postgres:17-alpine"

  # Named as in terraform/openbao (modules/project-secrets): <project>-<environment>.
  mlflow_provider_name = "mlflow-production"
  # Empty in a PR's plan until the apply has added mlflow to terraform/openbao, which runs before this
  # root on merge (tofu.yml). So one PR is enough.
  mlflow_provider_token = try(data.terraform_remote_state.openbao.outputs.dokploy_providers[local.mlflow_provider_name].token, "")

  mlflow_env = join("\n", [
    for k in ["S3_ACCESS_KEY_ID", "S3_SECRET_ACCESS_KEY", "S3_ENDPOINT", "S3_REGION", "S3_BUCKET"] :
    "${k}=$${{vault.${local.mlflow_provider_name}.mlflow/production/storage:${k}}}"
  ])

  # Same router pattern as OpenBao's (openbao.tf): http redirects to https.
  mlflow_labels = [
    "traefik.enable=true",
    "traefik.docker.network=dokploy-network",
    "traefik.http.services.mlflow.loadbalancer.server.port=5000",

    "traefik.http.routers.mlflow-web.rule=Host(`${local.mlflow_host}`)",
    "traefik.http.routers.mlflow-web.entrypoints=web",
    "traefik.http.routers.mlflow-web.middlewares=redirect-to-https@file",
    "traefik.http.routers.mlflow-web.service=mlflow",

    "traefik.http.routers.mlflow.rule=Host(`${local.mlflow_host}`)",
    "traefik.http.routers.mlflow.entrypoints=websecure",
    "traefik.http.routers.mlflow.tls.certresolver=letsencrypt",
    "traefik.http.routers.mlflow.service=mlflow",
  ]
}

# terraform/openbao's state, for the mlflow-production provider token.
data "terraform_remote_state" "openbao" {
  backend = "s3"
  config = {
    bucket    = "kthais-tfstate"
    key       = "openbao/terraform.tfstate"
    endpoints = { s3 = "https://objects.dc-sto1.glesys.net" }
    region    = "us-east-1"

    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

# Its own Dokploy project, so its vault provider can't be used for secret/infrastructure/*.
resource "dokploy_project" "mlflow" {
  name        = "mlflow"
  description = "MLflow for the research team, managed by github.com/kthaisociety/infrastructure (terraform/dokploy/mlflow.tf)"
}

# Lets the compose resolve ${{vault.mlflow-production.…}}. The token's policy,
# dokploy-project-mlflow-production, reads secret/mlflow/production and what's under it, nothing else.
resource "dokploy_vault_provider" "mlflow" {
  name = local.mlflow_provider_name

  hashicorp = {
    url              = "http://openbao:8200"
    mount            = "secret"
    token_wo         = local.mlflow_provider_token
    token_wo_version = parseint(substr(sha256(local.mlflow_provider_token), 0, 8), 16)
  }
  assignments = [{
    project_id      = dokploy_project.mlflow.id
    environment_ids = [dokploy_project.mlflow.production_environment_id]
  }]
  verify_connection = true
}

resource "dokploy_compose" "mlflow" {
  name            = "mlflow"
  description     = "MLflow, at https://${local.mlflow_host} (no sign-in yet)"
  environment_id  = dokploy_project.mlflow.production_environment_id
  compose_type    = "docker-compose"
  app_name_prefix = "mlflow"
  env             = local.mlflow_env

  # Compose interpolates `$`: ${VAR} is read from the env above, and $$ is a literal $ for the shell.
  raw = {
    compose_file = yamlencode({
      services = {
        postgres = {
          image   = local.mlflow_postgres_image
          restart = "unless-stopped"
          environment = {
            POSTGRES_USER             = "mlflow"
            POSTGRES_DB               = "mlflow"
            POSTGRES_HOST_AUTH_METHOD = "trust"
          }
          volumes  = ["mlflow-postgres-data:/var/lib/postgresql/data"]
          networks = ["mlflow"]
          healthcheck = {
            test     = ["CMD", "pg_isready", "-U", "mlflow", "-d", "mlflow"]
            interval = "10s"
            timeout  = "5s"
            retries  = 5
          }
        }

        mlflow = {
          image   = local.mlflow_image
          restart = "unless-stopped"
          # `db upgrade` creates the tables in an empty database and migrates an older one, then the server
          # starts, configured by the environment.
          command = ["sh", "-c", "mlflow db upgrade \"$$MLFLOW_BACKEND_STORE_URI\" && exec mlflow server"]
          environment = {
            MLFLOW_HOST                         = "0.0.0.0"
            MLFLOW_PORT                         = "5000"
            MLFLOW_BACKEND_STORE_URI            = "postgresql://mlflow@postgres:5432/mlflow"
            MLFLOW_ARTIFACTS_DESTINATION        = "s3://$${S3_BUCKET}"
            MLFLOW_S3_ENDPOINT_URL              = "$${S3_ENDPOINT}"
            MLFLOW_BOTO_CLIENT_ADDRESSING_STYLE = "path"
            AWS_ACCESS_KEY_ID                   = "$${S3_ACCESS_KEY_ID}"
            AWS_SECRET_ACCESS_KEY               = "$${S3_SECRET_ACCESS_KEY}"
            AWS_DEFAULT_REGION                  = "$${S3_REGION}"
            # Without these, MLflow answers 403 to any Host but localhost, and to the UI's own POSTs.
            # localhost:5000 is for checks from inside the container.
            MLFLOW_SERVER_ALLOWED_HOSTS        = "${local.mlflow_host},localhost:5000"
            MLFLOW_SERVER_CORS_ALLOWED_ORIGINS = "https://${local.mlflow_host}"
          }
          depends_on = { postgres = { condition = "service_healthy" } }
          networks   = ["mlflow", "dokploy-network"]
          labels     = local.mlflow_labels
        }
      }

      networks = {
        mlflow            = {}
        "dokploy-network" = { external = true }
      }
      volumes = { "mlflow-postgres-data" = {} }
    })
  }

  depends_on = [dokploy_vault_provider.mlflow]

  # Dokploy deletes a compose's volumes with it, so replacing this loses the database (tested locally,
  # 2026-11-09). Removing it is a deliberate change of its own, after a fresh backup.
  lifecycle {
    prevent_destroy = true
  }
}

# Like deployments' production databases: a pg_dump to the destination in core.tf, daily at 00:00 UTC,
# the last 30 kept, at kthais-database-backups/<app_name>_postgres/.
resource "dokploy_backup" "mlflow_postgres" {
  service_id            = dokploy_compose.mlflow.id
  service_type          = "compose"
  service_name          = "postgres"
  compose_database_type = "postgres"
  compose_database_user = "mlflow"
  database              = "mlflow"
  destination_id        = dokploy_destination.database_backups.id
  prefix                = "/"
  cron_expression       = "0 0 * * *"
  keep_latest_count     = 30
}
