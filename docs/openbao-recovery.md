# OpenBao: getting a root token, and CI's login

Tested procedures for the two things that cost us an evening on 2026-10-01: getting a root token with
recovery keys on OpenBao 2.7, and the subject (`sub`) CI's GitHub login must be bound to. Follow these as
written. What we tried that did **not** work is at the end, so nobody tries it again.

Values: OpenBao 2.7.0, single node, static seal (auto-unseal), recovery keys 3 shares / threshold 2
(runbook B1). Host `synapse.aisociety.se`; Docker needs `sudo`; the image is Alpine, so the container shell
is `sh` (BusyBox), and it has no Python.

## When you need a root token

Almost never. Root is revoked after init (runbook B5), and everything else goes through CI or the
`infra-admin` logins. You need one only for something no policy allows, e.g.:

- CI can't log in to OpenBao (its role is wrong), so `terraform/openbao` can't fix itself. That's what
  happened on 2026-10-01.
- A policy or auth method was broken so that nobody can reach what they need.

If CI can still log in, fix things with a PR to `terraform/openbao` instead: CI's `terraform` policy can
do everything.

## Get a root token with recovery keys (OpenBao 2.7)

**Why it isn't one command.** Since OpenBao 2.5.3 the old, unauthenticated `sys/generate-root/*`
endpoints are off by default (`disable_unauthed_generate_root_endpoints = true`), and the 2.7 CLI's
`bao operator generate-root` uses the new `sys/generate-root-token/*` endpoints, which **need a token**.
With no token, every CLI form of it fails with `403 permission denied`, including `-init`, `-cancel` and,
surprisingly, `-decode` (it reads the attempt status from the server first). So: turn the old endpoints
on for a moment, on a listener only reachable from inside the container; use them through `bao write`;
decode the token outside OpenBao.

**Who:** an infra admin with SSH to the host, and two recovery key holders (runbook B1: Sam, Vilhelm,
the org break-glass vault). Each holder types their own key at a hidden prompt. About 15 minutes.

**Never paste a key, the OTP, the encoded token or the root token anywhere but these prompts:** not in
chat, not in Claude Code (`!` commands land in the conversation), not as a command argument.

### 1. Add a loopback-only listener with the old endpoints on

In the Dokploy UI: project **infrastructure** → **openbao** → the compose file (raw). On the
`BAO_LOCAL_CONFIG` line, find exactly:

```
{\"tcp\":{\"address\":\"0.0.0.0:8200\",\"tls_disable\":true}}
```

and replace it with:

```
[{\"tcp\":{\"address\":\"0.0.0.0:8200\",\"tls_disable\":true}},{\"tcp\":{\"address\":\"127.0.0.1:8210\",\"tls_disable\":true,\"disable_unauthed_generate_root_endpoints\":false}}]
```

Save, then **Deploy**. OpenBao restarts and auto-unseals. Port 8210 is bound to the container's own
loopback: nothing on `dokploy-network` can reach it, only a shell inside the container. The next
`terraform/dokploy` apply writes the compose from code again, which removes it.

Don't turn the flag on for the main listener: every container on `dokploy-network` could then start or
cancel a root generation.

### 2. Shell in the container, pointed at that listener

```sh
ssh sam@synapse.aisociety.se
BAO=$(sudo docker ps -q --filter label=com.docker.compose.service=openbao)
sudo docker exec -it -e BAO_ADDR=http://127.0.0.1:8210 "$BAO" sh
```

### 3. Start the generation

```sh
bao read sys/generate-root/attempt        # started false; if true, cancel first:
# bao delete sys/generate-root/attempt
bao write -f sys/generate-root/attempt
```

Note `nonce` and `otp` from the output. The OTP is needed only to
decode the result; keep it on screen. If `started` was already true and you didn't start it, someone
else did: cancel it and find out who before going on.

### 4. Two recovery keys

Each holder, in turn (BusyBox `read -s` works):

```sh
read -rs K
bao write sys/generate-root/update nonce=<nonce> key="$K"; unset K
```

After the first: `progress 1`, `complete false`. After the second: `complete true` and an
`encoded_token`.

### 5. Decode the root token, outside OpenBao

`bao operator generate-root -decode` doesn't work without a token (above). The encoded token is the root
token XORed with the OTP, base64-encoded; decode it yourself. On a laptop with Python (the prompts are
hidden; nothing is left in shell history or the process list):

```sh
python3 -c 'import base64,getpass; e=getpass.getpass("encoded_token: ").strip(); o=getpass.getpass("otp: ").strip(); b=base64.b64decode(e.replace("-","+").replace("_","/")+"="*(-len(e)%4)); print(bytes(x^y for x,y in zip(b,o.encode())).decode())'
```

The host has no Python. To keep the token off a laptop, run the same code on the host in a throwaway
container with no network: `sudo docker run --rm -it --network none python:3-alpine python3 -c '<same>'`.

The result starts with `s.` and is as long as the OTP. **Shorter means one of the two values was pasted
incomplete**: the XOR stops at the shorter input. Paste both again in full. Then `clear` the terminal.

### 6. Use it, in the container shell

```sh
read -rs BAO_TOKEN && export BAO_TOKEN
bao token lookup | grep policies          # [root]
```

If `lookup` gives `403 permission denied`, the variable is empty or wrong: check with
`echo "len=${#BAO_TOKEN} start=$(echo "$BAO_TOKEN" | cut -c1-2)"` **in the container** (not in Claude
Code or a laptop shell). Expect `start=s.` and the OTP's length.

Do the fix. Only what can't be done through CI; then make the code match it, so the next apply doesn't
undo it.

### 7. Revoke it and clean up

```sh
bao token revoke -self
unset BAO_TOKEN
exit
```

Run a `terraform/dokploy` apply (any merge that touches `terraform/`, or rerun the last `tofu` run) to
remove the 8210 listener. Until then it's reachable only from inside the container.

## CI's login: the `sub` it must be bound to

CI logs in with GitHub's OIDC token to the JWT role `infrastructure-ci`, bound on `sub`. The format of
`sub` is a **repo setting**, so check it before writing or changing the role:

```sh
gh api repos/kthaisociety/infrastructure/actions/oidc/customization/sub
# {"use_default":true,"use_immutable_subject":true,"sub_claim_prefix":"repo:kthaisociety@57193069/infrastructure@1397232852"}
```

- This repo uses GitHub's **immutable subject**: the owner and repo carry their numeric IDs, so a
  renamed or re-created repo with the same name can't match. A job in the `production` environment gets
  `repo:kthaisociety@57193069/infrastructure@1397232852:environment:production`; a PR job gets
  `…:pull_request`.
- GitHub's docs show the name-only form (`repo:kthaisociety/infrastructure:environment:production`).
  That form is **not** what this repo's tokens carry, and binding it fails every login with
  `claim "sub" does not match any associated bound claim values`.
- **It can't be turned off.** `PUT …/oidc/customization/sub` with `use_immutable_subject=false` returns
  `{}` (success) and changes nothing; a custom template (`use_default=false`,
  `include_claim_keys=["repo","environment"]`) still renders the immutable prefix. Don't plan around
  switching it.
- `openbao-validate` (PRs) decodes a PR token's `sub` and fails if its `repo:…` part differs from the
  role's binding in `terraform/openbao/main.tf`. It's the only place the binding is checked before
  `main`: `openbao-apply` is the first real login.
- After creating or changing the role by hand, prove it before building on it: rerun `openbao-apply` (or
  dispatch `tofu` on `main`) and see it get past `auth/jwt/login`.

## What happened on 2026-10-01, and what didn't work

1. **B2 bound the name-only `sub`.** We wrote it from GitHub's docs without checking the repo setting.
   The first `openbao-apply` (after #6) failed at login, before changing anything.
2. **Tried: switch the repo to name-only subjects for one apply** (#7's original plan). The PUT
   "succeeds" and is ignored (above). The rerun failed the same way.
3. **Tried: `bao operator generate-root -init`** with two recovery keys ready. `403 permission denied`:
   the CLI uses the authenticated endpoint, and the old one is off since 2.5.3.
4. **Fix:** loopback listener with the old endpoints on, `bao write sys/generate-root/*`, decode
   outside OpenBao, rewrite the role with the immutable `sub`, revoke root. **Also tried and failed on
   the way:** `bao operator generate-root -decode` (403, needs a token); Python on the host (not
   installed); checking `$BAO_TOKEN` through Claude Code's `!` (that's the laptop's shell, not the
   container's).
5. The rerun logged in: `4 imported, 14 added, 0 changed`. The imports matched B2/B3 exactly, so the
   role written in step 4 is identical to `terraform/openbao`'s.

Lesson for anything done by hand inside OpenBao: run the login or call that depends on it right away,
while the root token still exists. Revoking root first turned a one-line fix into this procedure.
