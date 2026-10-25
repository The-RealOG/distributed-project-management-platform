# Frontend: static build served by unprivileged nginx.
#   docker build -f infrastructure/docker/web.Dockerfile \
#     --build-arg VITE_API_BASE_URL=http://localhost:3000/api .
# Exact versions, so a rebuild of the same commit gets the same base; Dependabot proposes updates.
ARG NODE_IMAGE=node:24.22.0-alpine3.24

FROM ${NODE_IMAGE} AS prune
WORKDIR /repo
COPY . .
RUN npx --yes turbo@2.11.4 prune @dpp/web --docker

FROM ${NODE_IMAGE} AS build
WORKDIR /app
COPY --from=prune /repo/out/json/ ./
# The npm cache is a BuildKit cache mount: packages are downloaded once and reused across
# images and rebuilds (and a build that fails part-way keeps what it fetched). Retries ride out
# transient registry/network resets.
RUN --mount=type=cache,target=/root/.npm,sharing=locked \
    npm ci --ignore-scripts --prefer-offline --fetch-retries=5 --fetch-retry-mintimeout=20000 --fetch-retry-maxtimeout=120000
COPY --from=prune /repo/out/full/ ./
COPY tsconfig.base.json ./
# Vite inlines these at build time; the browser only ever learns the gateway's address.
ARG VITE_API_BASE_URL
ARG VITE_DEV_LOGIN_ENABLED=false
ENV VITE_API_BASE_URL=${VITE_API_BASE_URL} VITE_DEV_LOGIN_ENABLED=${VITE_DEV_LOGIN_ENABLED}
RUN test -n "$VITE_API_BASE_URL" && npx turbo run build --filter=@dpp/web...

# Runs as a non-root user and listens on 8080.
FROM nginxinc/nginx-unprivileged:1.31.7-alpine3.24 AS runtime
# OS security fixes published since the base image was built (the CI scan fails on any fixable
# HIGH/CRITICAL), then back to the image's unprivileged nginx user.
USER 0
RUN apk upgrade --no-cache
USER 101
COPY infrastructure/docker/web-nginx.conf.template /etc/nginx/templates/default.conf.template
COPY --from=build /app/apps/web/dist /usr/share/nginx/html
EXPOSE 8080
