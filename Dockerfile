# syntax=docker/dockerfile:1

ARG NODE_IMAGE=node:24-bookworm-slim

FROM ${NODE_IMAGE} AS builder

WORKDIR /opt/sidemesh

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      g++ \
      make \
      python3 \
    && rm -rf /var/lib/apt/lists/*

COPY package.json package-lock.json tsconfig.json ./
COPY scripts ./scripts
COPY src ./src

RUN npm ci \
    && npm run typecheck \
    && npm run build \
    && npm prune --omit=dev

FROM ${NODE_IMAGE} AS runtime

ARG CODEX_VERSION=0.145.0

ENV HOME=/home/node \
    NODE_ENV=production \
    SIDEMESH_PORT=8787 \
    SIDEMESH_STATE_DIR=/home/node/.sidemesh

RUN apt-get update \
    && apt-get install --yes --no-install-recommends \
      ca-certificates \
      git \
      openssh-client \
      ripgrep \
    && npm install --global "@openai/codex@${CODEX_VERSION}" \
    && npm cache clean --force \
    && rm -rf /var/lib/apt/lists/* \
    && mkdir -p /home/node/.codex /home/node/.sidemesh /workspace \
    && chown -R node:node /home/node /workspace

WORKDIR /workspace

COPY --from=builder --chown=node:node /opt/sidemesh/package.json /opt/sidemesh/package-lock.json /opt/sidemesh/
COPY --from=builder --chown=node:node /opt/sidemesh/dist /opt/sidemesh/dist
COPY --from=builder --chown=node:node /opt/sidemesh/node_modules /opt/sidemesh/node_modules

USER node

EXPOSE 8787

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:' + (process.env.SIDEMESH_PORT || '8787') + '/healthz').then((response) => { if (!response.ok) process.exit(1); }).catch(() => process.exit(1));"

CMD ["node", "/opt/sidemesh/dist/cli.js", "daemon", "--allow-duplicate"]
