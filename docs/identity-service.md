# Identity service: infrastructure notes

The identity service now has its own repo:
**[kthaisociety/identity-service](https://github.com/kthaisociety/identity-service)**. Its README and
decision records (`docs/adr/`) are the source of truth for what it does and how. In short: it owns sign-in
(OIDC) for every KTHAIS app, users and roles, and kthais.com Google Workspace accounts, and it's the only
service that holds Google credentials.

This page keeps only what concerns this repo: Google OAuth clients, GCP, and deploying the service.

## Before it can deploy

The service runs two listeners
([ADR 0003](https://github.com/kthaisociety/identity-service/blob/main/docs/adr/0003-two-listeners.md)):
a public one for sign-in and an internal one for the admin API. It registers like any other project
([app-delivery.md](app-delivery.md), 2.2 and 2.4):

- **Here:** one line in `terraform/openbao/projects.yaml`.
- **In `kthaisociety/deployments`:** `projects/identity-service/project.yaml` and `release.yaml`.

Deploying it also needs what the pipeline doesn't support yet:

- **Postgres** for the project.
- **A public domain** (e.g. `auth.kthais.com`) for the public listener only. The internal listener never
  gets a domain.

## Google OAuth clients today

Every client in use and the project that holds it is listed in
[gcp.md](gcp.md#projects-being-retired). The two that matter here:

| Client | GCP project | Owner |
|---|---|---|
| kthais.com sign-in | `clean-healer-452020-n9` ("website") | vilhelm only |
| Mattermost (chat.aisociety.se) | `mattermost-423409` | vilhelm only |

The identity service gets a **new** Google OAuth client in its own GCP project, `kthais-identity`, which
`terraform/gcp` created on 2026-10-13 ([gcp.md](gcp.md)). The project, its APIs and its owners are in
code. The client isn't made yet: as far as we know, Google has no API for creating standard OAuth client
IDs, so it's created by hand once in that project. Its authorized redirect URIs are only the identity
service's own callbacks, one per environment.

The project is meant to be owned by a Google group rather than by people. Until that group exists, its
owners are sam and vilhelm.

Apps register with the identity service instead of Google. Their allowed redirect URIs are an exact-match
allowlist in the identity service's config, set through env in `deployments`
([ADR 0005](https://github.com/kthaisociety/identity-service/blob/main/docs/adr/0005-redirect-uri-allowlist-in-config.md)).

The existing kthais.com client is retired once kthais.com has moved to the identity service. Mattermost
may keep its own client if it can't use the identity service as an OIDC provider on our edition.

## Known bug in the current sign-in

Until kthais.com moves over, `landingpage-backend` still does its own Google sign-in. As of `9baf255`,
`GoogleCallback` (`internal/handlers/auth_handler.go`) uses the token's claims even when
`utils.ParseAndVerifyGoogle` says the token is invalid, and `ParseAndVerifyGoogle` never checks `aud` or
`email_verified`. It's a live security bug in that repo.

## Open questions

- Can Mattermost use the identity service as a generic OIDC provider on our Mattermost edition? If not,
  it keeps its own Google client.
- How staging tests Google Workspace changes without touching real accounts: a staging OU in the
  kthais.com Workspace with its own narrowly scoped service account, or a separate Workspace. Not
  decided.
