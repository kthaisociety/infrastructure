# Google Cloud

_Written 2026-10-11. The provisioner project was made on 2026-10-12, and `kthais-identity` and
`kthais-mattermost` were created by the first apply on 2026-10-13. Still open: whether those two are
owned by named people or by a Google group._

KTHAIS uses Google Cloud for almost nothing but sign-in. An audit of the kthais.com organization on
2026-10-11 found 42 projects and, across all of them, no machines, buckets or databases that we run.
What we rely on is a handful of sign-in clients and one service account.

The organization is being reduced to three projects:

| Name | ID | How it's made | What it holds |
|---|---|---|---|
| provisioner | set in `tofu.yml`, see below | By hand, once. The only project that isn't in code | The accounts CI runs OpenTofu as, and the sign-in from GitHub Actions |
| identity | `kthais-identity` | By OpenTofu | The one Google sign-in client, used by the [identity service](identity-service.md), and the account that manages Google Workspace |
| mattermost | `kthais-mattermost` | By OpenTofu | Mattermost's sign-in client |

### Why the IDs start with `kthais-`

We call the projects provisioner, identity and mattermost, and those are their names in the console.
Their IDs can't be those words:

- **An ID has to be unique across all of Google Cloud**, not only inside our organization. Bare words
  are long gone: someone else's project is already `mattermost`.
- **Left to itself, Google adds a random number**, which is how the old projects got IDs like
  `mattermost-423409` and `clean-healer-452020-n9`. Those say nothing about whose they are.
- **An ID can never be changed**, and it shows up everywhere: in code, in service account addresses
  (`workspace-admin@kthais-identity.iam.gserviceaccount.com`) and in logs.

So each ID is `kthais-` plus the name: readable, clearly ours, and chosen once.

Every project that exists today is on its way out ([Projects being retired](#projects-being-retired)).

## What's in code

`terraform/gcp` creates `kthais-identity` and `kthais-mattermost`: the project, its owners, the APIs it
needs, and in `kthais-identity` the `workspace-admin` service account. The list is `local.projects` in
[`projects.tf`](../terraform/gcp/projects.tf).

Google also turns on about twenty APIs of its own on every new project (BigQuery, Cloud Storage, Logging,
Monitoring and others), on top of the ones we enable. They're free, we don't use them, and the code
leaves them alone. The provisioner project has them too.

A project's owners are exactly the members listed there, plus CI: someone made owner by hand is removed
by the next apply. Other roles on a project aren't touched. For now the list is the two organization
admins; [identity-service.md](identity-service.md) calls for a Google group, which has to exist first.

## Made by hand

These can't be in code. Each is listed here so it can be rebuilt.

### Sign-in clients

Google has no API to create the OAuth clients behind "Sign in with Google", as far as we know. They're
made in the console (APIs & Services → Credentials) of the project that holds them.

| Project | Client | Used by | Its ID and secret are set in |
|---|---|---|---|
| `kthais-identity` | not made yet | the identity service, and through it every KTHAIS app | |
| `kthais-mattermost` | not made yet | `chat.aisociety.se` | Mattermost's own settings |

When a client is made, write its name and redirect addresses here.

- **A secret is shown once**, when it's made. If one is lost, add a new secret to the same client rather
  than making a new client: the client ID and redirect addresses stay.
- **Google deletes a client nobody has signed in through for six months**, after marking it "unused" in
  the console. A deleted client can be restored for 30 days.

### The Workspace admin account

`workspace-admin` in `kthais-identity` is in code. Two things about it aren't:

- **Its key.** A key made by OpenTofu would sit in state, so it's made in the console and put in OpenBao.
- **Its right to act as a Workspace admin.** A Workspace super admin grants it in the Google Workspace
  admin console (Security → API controls → Domain-wide delegation), to the account's client ID,
  `106879629454145161083`. Nothing in Google Cloud shows or controls it. The ID isn't secret. It changes
  only if the account is ever made again, and `terraform/gcp` prints the current one as
  `workspace_admin_client_id` on every apply.

### Access to the whole organization

Who is an organization admin, and what every kthais.com account may do, is set on the organization by
hand. Today every kthais.com account can create projects and billing accounts, which is Google's default
and why the organization grew to 42 projects.

### Billing

Neither project is linked to a billing account, and neither needs one: sign-in clients and the APIs we
use are free. When KTHAIS's central billing account exists
([plan.md](plan.md#later-gcp-as-code) has the steps), set `billing_account` in
[`variables.tf`](../terraform/gcp/variables.tf) and, by hand, give CI's apply account the Billing
Account User role on that account.

## The provisioner project

CI can't create the identity it signs in with, so this one project is made by hand and stays out of the
code. That also means CI can't change its own sign-in, by mistake or otherwise. It was made on 2026-10-12
with the steps below, which are kept so it can be rebuilt.

It holds two service accounts: the **plan account**, read-only, for PRs, and the **apply account**, for
`main`.

**The project's ID and the two accounts' names are written in one place:** `GCP_PROVISIONER_PROJECT`,
`GCP_PLAN_ACCOUNT` and `GCP_APPLY_ACCOUNT` at the top of
[`.github/workflows/tofu.yml`](../.github/workflows/tofu.yml). The gcp jobs build the accounts' addresses
from them and pass them to `terraform/gcp`, and the commands below read them from there. None of the three
can be changed once created.

Steps 1 and 2 can be run by any kthais.com account, which then owns the project. Step 3 needs an
organization admin. Run them from the root of this repo, in bash or zsh.

Two things in the commands are there on purpose:

- **`--billing-project`** makes gcloud count a request against the new project. Without it gcloud uses a
  shared project of its own, which is rate-limited and refuses the sign-in commands outright, even for
  the project's owner.
- **Braces around every variable**, as in `${P}`. In zsh, the default shell on macOS,
  `$SUBJECT:environment` is read as `$SUBJECT` with a modifier, and the value is lost.

1. The project, its APIs and the sign-in. CI's requests count against this project, so every API CI
   calls is enabled here. All are free. The `echo` prints what is about to be created: check it before
   going on.

   ```sh
   setting() { sed -n "s/^  ${1}: *//p" .github/workflows/tofu.yml; }
   P=$(setting GCP_PROVISIONER_PROJECT)
   PLAN=$(setting GCP_PLAN_ACCOUNT)
   APPLY=$(setting GCP_APPLY_ACCOUNT)
   echo "project: ${P}  accounts: ${PLAN}, ${APPLY}"

   gcloud projects create "${P}" --name="provisioner" --organization=914442966401
   gcloud services enable --project="${P}" \
     cloudbilling.googleapis.com cloudresourcemanager.googleapis.com iam.googleapis.com \
     iamcredentials.googleapis.com serviceusage.googleapis.com sts.googleapis.com

   gcloud iam workload-identity-pools create github --project="${P}" --billing-project="${P}" \
     --location=global --display-name="GitHub Actions"
   gcloud iam workload-identity-pools providers create-oidc github \
     --project="${P}" --billing-project="${P}" --location=global \
     --workload-identity-pool=github --display-name="GitHub Actions" \
     --issuer-uri=https://token.actions.githubusercontent.com \
     --attribute-mapping=google.subject=assertion.sub \
     --attribute-condition="assertion.repository_owner_id == '57193069' && assertion.repository_id == '1397232852'"
   ```

2. The two service accounts, each usable from one environment of this repo:

   ```sh
   gcloud iam service-accounts create "${PLAN}" --project="${P}" --billing-project="${P}" \
     --display-name="OpenTofu plan (GitHub Actions, read-only)"
   gcloud iam service-accounts create "${APPLY}" --project="${P}" --billing-project="${P}" \
     --display-name="OpenTofu apply (GitHub Actions)"

   N=$(gcloud projects describe "${P}" --billing-project="${P}" --format='value(projectNumber)')
   SUBJECT="principal://iam.googleapis.com/projects/${N}/locations/global/workloadIdentityPools/github/subject/repo:kthaisociety@57193069/infrastructure@1397232852"
   gcloud iam service-accounts add-iam-policy-binding "${PLAN}@${P}.iam.gserviceaccount.com" \
     --project="${P}" --billing-project="${P}" --role=roles/iam.workloadIdentityUser \
     --member="${SUBJECT}:environment:plan"
   gcloud iam service-accounts add-iam-policy-binding "${APPLY}@${P}.iam.gserviceaccount.com" \
     --project="${P}" --billing-project="${P}" --role=roles/iam.workloadIdentityUser \
     --member="${SUBJECT}:environment:production"
   ```

3. Let the apply account create projects in the organization:

   ```sh
   gcloud organizations add-iam-policy-binding 914442966401 --billing-project="${P}" \
     --role=roles/resourcemanager.projectCreator \
     --member="serviceAccount:${APPLY}@${P}.iam.gserviceaccount.com"
   ```

4. Put the project number (`echo "${N}"`) into `GCP_WORKLOAD_IDENTITY_PROVIDER`, the line below those
   three in `.github/workflows/tofu.yml`. Nothing else needs the ID, the names or the number.

## How CI signs in

A job in `.github/workflows/tofu.yml` trades its GitHub OIDC token for a short-lived Google token. There
are no key files.

| Job | GitHub environment | Becomes | May |
|---|---|---|---|
| `gcp-plan` (PRs) | `plan`: a reviewer approves each run | the plan account | read the projects in `terraform/gcp`: Viewer and Security Reviewer, granted in code |
| `gcp-apply` (`main`) | `production`: `main` only | the apply account | create projects in the organization, and everything in the ones it created: Owner |

- Google accepts tokens from this repo only, matched by GitHub's org and repo IDs, not their names.
- Each service account can be used from exactly one environment.
- As owner of `kthais-identity` and `kthais-mattermost`, the apply account could read the sign-in
  clients' secrets. `production` already holds secrets of that weight.
- Neither account has any role in the provisioner project itself.

**If CI can't sign in**, the cause is in the provisioner project or on GitHub's side, since nothing in
this repo can change the sign-in. Compare the project with the steps above and repair it by hand.

## Adding a project

Add it to `local.projects`. The next apply creates it, with CI and the listed people as its owners.

On the PR that adds it, `gcp-plan` can't read the new project yet: the plan account's Viewer and Security
Reviewer roles on it are granted by this same code. The plan just shows the project as new, and the roles
exist once that PR is applied.

## Projects being retired

None of the projects that existed before this module is in code. Each stays as it is until nothing uses
it, then it's deleted. Sign-in runs on three of them today:

| Project | Holds | Goes when |
|---|---|---|
| `clean-healer-452020-n9` ("website") | Sign-in clients: `production-client` (kthais.com), `kortslutning-production` (`app.ktha.is`), `openbao` (`bao.kthais.com`), and `dev-client` (**use not known**, made 2026-09-27) | kthais.com, kortslutning and OpenBao sign in through the identity service |
| `mattermost-423409` | Sign-in client `Mattermost - KTH AI Society` (`chat.aisociety.se`) | Mattermost is switched to a new client in `kthais-mattermost` |
| `kthais-website-492616` ("KTHAIS-website") | `onboarding-service-account` and its key, in OpenBao as `GOOGLE_ADMIN_SERVICE_ACCOUNT_JSON` ([onboarding-service-migration.md](onboarding-service-migration.md)) | the identity service manages Workspace with `workspace-admin` |

`production-client` and Mattermost's client are confirmed by where the live sites send a sign-in. The
other two named clients are matched by name only.

> ⚠️ **A project that only holds sign-in clients looks dead.** It has no resources, makes no API calls and
> never changes, so every usage signal Google offers says it's unused. `mattermost-423409` is one, and
> deleting it today would lock everyone out of Mattermost. Before deleting any project, open its
> Credentials page in the console and look for clients.

**Members' own projects.** A project that exists only for Google sign-in isn't needed: the app should
sign in through the identity service instead. Projects with another purpose, and the ones Google makes on
its own for AI Studio API keys, are decided case by case.
