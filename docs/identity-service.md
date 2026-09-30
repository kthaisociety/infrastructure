# Identity service plan

_Written 2026-09-30. Status: agreed direction, secondary to the infrastructure plan, nothing built. This lives here until the service has its
own repo; move it there then._

## Goal

One small Go service owns Google Workspace sign-in, roles and token issuing for every KTHAIS app. Apps
stop talking to Google directly. Today that logic lives in `landingpage-backend`, and every other app
that wants "Sign in with Google" needs its own OAuth client.

Keycloak and similar are too heavy for a volunteer team. We keep the service small and readable, but
standards-shaped (OIDC), so it could be swapped for Zitadel or Keycloak later without changing the apps.

## How it works

```
app ──(1) redirect: client_id, redirect_uri, state, PKCE──▶ identity
identity ──(2) Google sign-in, its own OAuth client──▶ Google
Google ──(3) callback to identity's own URL──▶ identity
identity ──(4) redirect to the app's registered redirect_uri with a one-time code──▶ app
app backend ──(5) exchange code (+ PKCE verifier / client secret) for tokens──▶ identity
```

- **Identity is the only Google OAuth client.** Google's authorized redirect URIs contain only the
  identity service's own callback, one per environment (prod, staging, localhost). Adding an app never
  touches Google.
- **Apps are OIDC clients of the identity service, not of Google.** Each app is registered in the
  identity service's config, in code: a `client_id`, its allowed `redirect_uri`s, and whether it's a
  confidential client (has a backend that holds a secret) or public (PKCE only).
- **Redirect URIs are an exact-match allowlist per client.** No wildcards, no prefix matching, and never
  "redirect to whatever URL the request says". Otherwise the identity service becomes an open redirect
  that hands signed-in sessions to any site.
- **Authorization code flow with PKCE.** The app receives a short-lived, single-use code in the
  redirect and exchanges it server-side for tokens. Tokens never travel in URLs.
- **Standard token shape:** short-lived signed JWTs with `iss`, `aud` (the app's `client_id`), `sub`,
  `exp`, plus our role claims. Public keys served at a JWKS endpoint, with a discovery document
  (`/.well-known/openid-configuration`), so apps verify tokens with any OIDC library. Suggested
  library: `zitadel/oidc`.
- **Apps must check `aud`.** A token issued for one app must be rejected by every other app.
- **Single sign-on across apps.** The identity service keeps its own session cookie on its own domain
  (e.g. `auth.kthais.com`). When a second app redirects there, the user is already signed in and goes
  straight back with a code, without seeing Google again. Each app still has its own short-lived tokens
  and its own app session.
- **Sign-out** ends the identity session, so no app can get new tokens. Apps' existing tokens expire on
  their own (keep them short). If we need instant sign-out everywhere, add OIDC back-channel logout
  later.

## What identity must verify from Google

Before trusting a Google sign-in, check the ID token's signature against Google's JWKS, plus `iss`,
`aud` (our Google client ID), `exp`, `email_verified`, and `hd == "kthais.com"` where Workspace-only
access is required.

## Step 1: fix verification in `landingpage-backend`

As of `landingpage-backend` `9baf255` (2026-09-27), `GoogleCallback`
(`internal/handlers/auth_handler.go`) calls `utils.ParseAndVerifyGoogle`, logs when the token is
invalid, and then **uses the claims anyway**. `ParseAndVerifyGoogle` (`internal/utils/jwt.go`) also
never checks `aud` or `email_verified`. Fix this first, in the existing backend: it's a live security
bug, and the fixed logic is what moves into the identity service.

## Step 2: build the service

- Endpoints: authorize, Google callback, token, JWKS, discovery, and userinfo if an app needs it.
- Client registry: a config file in the service's repo (reviewed in PRs). Client secrets for
  confidential clients live in OpenBao and reach apps through Dokploy `${{vault.…}}` references.
- Signing key in OpenBao, with rotation: JWKS publishes the current and previous key.
- Roles: move the role model from `landingpage-backend`.
- Deployed on Dokploy like everything else, as `terraform/dokploy/projects/identity/` in the
  infrastructure repo.

## Step 3: migrate apps

kthais.com (`landingpage-frontend` + `landingpage-backend`) first, then the other apps one at a time.
Each migration: register the client, switch the app to the OIDC flow, verify tokens via JWKS with an
`aud` check, then remove the app's own Google OAuth code.

## Google OAuth clients today

From the 2026-09-26 GCP audit (`~/kthais/gcp-project-audit-2026-09-26.md`):

| Client | GCP project | Owner |
|---|---|---|
| kthais.com sign-in | `clean-healer-452020-n9` ("website") | vilhelm only |
| Mattermost (chat.aisociety.se) | `mattermost-423409` | vilhelm only |

The identity service gets a **new** Google OAuth client in a **new GCP project defined in
`terraform/gcp`**, owned by a Google group rather than one person. As far as we know, Google has no API
for creating standard OAuth client IDs, so the project, its APIs and IAM are in code, and the client
itself is created by hand once in that project. That's fine, since it's the only one.

Mattermost is an exception: it can keep its own Google client if it can't use the identity service as
an OIDC provider on our edition. The existing kthais.com client is retired once kthais.com has moved to
the identity service.

## Open questions

- Can Mattermost use the identity service as a generic OIDC provider on our Mattermost edition? If not,
  it keeps its own Google client.
- Is instant sign-out across apps needed (back-channel logout), or is short token expiry enough?
