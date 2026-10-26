# The local CI runner: what the workflows' jobs use on ubuntu-latest, at the versions they pin. Built on
# the server and run there on dokploy-network, so it reaches http://dokploy:3000 and http://openbao:8200
# by name, as nothing on your machine can.
FROM python:3.12.15-slim-bookworm

# The workflows' TOFU_VERSION; yq is mikefarah's v4, as on GitHub's runners. For the server's
# architecture: amd64, or arm64 on Apple silicon (TARGETARCH, from the build).
ARG TARGETARCH
ARG TOFU_VERSION=1.12.6
ARG TOFU_SHA256_amd64=5dc43da4f750f33873dc25e94587128709e819e544b7be9016b255316153c3a8
ARG TOFU_SHA256_arm64=e573979ba68a17fe7b881752051a694a7efcd970e39521f6a25775197861ed4d
ARG YQ_VERSION=v4.54.1
ARG YQ_SHA256_amd64=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
ARG YQ_SHA256_arm64=189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b

RUN apt-get update \
  && apt-get install -y --no-install-recommends bash ca-certificates curl jq openssl unzip \
  && rm -rf /var/lib/apt/lists/*

RUN case "$TARGETARCH" in \
      amd64) tofu_sha=$TOFU_SHA256_amd64 yq_sha=$YQ_SHA256_amd64 ;; \
      arm64) tofu_sha=$TOFU_SHA256_arm64 yq_sha=$YQ_SHA256_arm64 ;; \
      *) echo "unsupported architecture: '$TARGETARCH'" >&2; exit 1 ;; \
    esac \
  && curl -fsSL -o /tmp/tofu.zip \
    "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_${TARGETARCH}.zip" \
  && echo "${tofu_sha}  /tmp/tofu.zip" | sha256sum -c - \
  && unzip -q /tmp/tofu.zip tofu -d /usr/local/bin \
  && rm /tmp/tofu.zip \
  && curl -fsSL -o /usr/local/bin/yq \
    "https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${TARGETARCH}" \
  && echo "${yq_sha}  /usr/local/bin/yq" | sha256sum -c - \
  && chmod +x /usr/local/bin/yq

COPY gh /usr/local/bin/gh
