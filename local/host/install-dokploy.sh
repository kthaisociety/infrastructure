#!/bin/sh
# Dokploy's installer (https://dokploy.com/install.sh), step by step, for the Docker-in-Docker server: the
# installer itself refuses to run in a container. The same swarm, network, secrets, services and mounts,
# with production's versions pinned. Runs on the server (kthais-dokploy) as root; does nothing once the
# swarm exists.
#   install-dokploy.sh <advertise address>
set -eu

DOKPLOY_IMAGE=dokploy/dokploy:v0.30.8 # production's (docs/openbao-deploy.md, A1)
POSTGRES_IMAGE=postgres:16
TRAEFIK_IMAGE=traefik:v3.7.13 # production's since runbook C0; the installer ships v3.6.25

advertise_addr=$1

if [ "$(docker info --format '{{.Swarm.LocalNodeState}}')" = active ]; then
  echo "Dokploy is already installed."
  exit 0
fi

docker swarm init --advertise-addr "$advertise_addr"
docker network create --driver overlay --attachable dokploy-network

mkdir -p /etc/dokploy
chmod 777 /etc/dokploy

openssl rand -base64 32 | tr -d "=+/" | cut -c1-32 | docker secret create dokploy_postgres_password -
openssl rand -hex 32 | docker secret create dokploy_auth_secret -

# One difference from production: both services use DNS round-robin, not a virtual IP. Some nested-Docker
# hosts can't route swarm's virtual IPs, and Dokploy then never reaches its Postgres (the Dokploy
# provider's acceptance rig does the same, for the same reason). Where virtual IPs work, nothing changes.
docker service create \
  --name dokploy-postgres \
  --endpoint-mode dnsrr \
  --constraint 'node.role==manager' \
  --network dokploy-network \
  --env POSTGRES_USER=dokploy \
  --env POSTGRES_DB=dokploy \
  --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
  --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  --mount type=volume,source=dokploy-postgres,target=/var/lib/postgresql/data \
  "$POSTGRES_IMAGE"

# RELEASE_TAG=latest: what the installer sets for a vX.Y.Z version.
docker service create \
  --name dokploy \
  --endpoint-mode dnsrr \
  --replicas 1 \
  --network dokploy-network \
  --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
  --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
  --mount type=volume,source=dokploy,target=/root/.docker \
  --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
  --secret source=dokploy_auth_secret,target=/run/secrets/dokploy_auth_secret \
  --publish published=3000,target=3000,mode=host \
  --update-parallelism 1 \
  --update-order stop-first \
  --constraint 'node.role == manager' \
  -e RELEASE_TAG=latest \
  -e POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
  -e BETTER_AUTH_SECRET_FILE=/run/secrets/dokploy_auth_secret \
  "$DOKPLOY_IMAGE"

# The installer sleeps 4 seconds here. Wait for Dokploy to write Traefik's config instead: a bind mount of
# a file that doesn't exist yet becomes an empty directory, and Traefik never starts.
echo "Waiting for Dokploy to write /etc/dokploy/traefik/traefik.yml..."
i=0
until [ -f /etc/dokploy/traefik/traefik.yml ]; do
  i=$((i + 1))
  if [ "$i" -gt 300 ]; then
    echo "Dokploy didn't write its Traefik config within 5 minutes: docker service logs dokploy" >&2
    exit 1
  fi
  sleep 1
done

docker run -d \
  --name dokploy-traefik \
  --restart always \
  --network dokploy-network \
  -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
  -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
  -v /var/run/docker.sock:/var/run/docker.sock:ro \
  -p 80:80/tcp \
  -p 443:443/tcp \
  -p 443:443/udp \
  "$TRAEFIK_IMAGE"

echo "Dokploy installed."
