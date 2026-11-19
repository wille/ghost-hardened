# syntax=docker/dockerfile:1
#
# Hardened Ghost image.
# - Reuses the official image's reproducible build (pinned by digest) as the builder.
# - Runtime is distroless (no shell, no package manager, no ghost-cli, no npm/pnpm).
# - Ghost's code is root-owned and read-only; only the content dir is writable.
# - Node's permission model: no child processes, no WASI, fs reads limited to the
#   install dir and /tmp, fs writes limited to content/ and /tmp.
#
# Installed at /ghost (not /var/lib/ghost): fs-extra's copy() stats every parent of
# the destination up to "/", and Node's fs grants are recursive, so a deep path would
# force granting read on /var. Content volume therefore mounts at /ghost/content.

# Base images are pinned by tag + digest as literal FROM lines so Dependabot can bump them.
FROM ghost:6.78.0@sha256:985ef9f30fb897a29050a9ef956bff1737ff1f2cd955aa5b759b88251f9c8735 AS build
RUN set -eux; \
    cp -a /var/lib/ghost /ghost; \
    cd /ghost; \
    rm -rf .pnpm-store config.development.json; \
    # Bundled-theme symlinks point at /var/lib/ghost; entrypoint.js copies themes instead.
    rm -f content.orig/themes/*; \
    # Resolve the "current" symlink so the tree has no links pointing elsewhere.
    ver="$(basename "$(readlink current)")"; rm current; mv "versions/$ver" current; rm -rf versions; \
    # Container-friendly config: new paths, stdout logging only, no systemd hints.
    node -e ' \
      const fs = require("fs"), f = "config.production.json"; \
      const c = JSON.parse(fs.readFileSync(f)); \
      c.paths = {contentPath: "/ghost/content"}; \
      c.logging = {transports: ["stdout"]}; \
      delete c.process; \
      fs.writeFileSync(f, JSON.stringify(c, null, 2) + "\n");'; \
    # Everything is root-owned and read-only to the runtime user...
    chown -R root:root /ghost; \
    chmod -R a-w,a+rX /ghost; \
    # ...except the content dir, owned by the distroless nonroot user (uid 65532).
    rm -rf content; mkdir content; chown 65532:65532 content; chmod 0750 content

FROM gcr.io/distroless/cc-debian12:nonroot@sha256:9dac0a79194e45a7da0158a9c6da57b217585af0786db3845d1f0ec1a0dd182f
# Node from the official image: the exact build Ghost's native addons were compiled for.
COPY --from=build /usr/local/bin/node /usr/local/bin/node
COPY --from=build /ghost /ghost
COPY --chown=root:root --chmod=0444 entrypoint.js addon-guard.js /ghost/

ENV NODE_ENV=production \
    GHOST_INSTALL=/ghost \
    GHOST_CONTENT=/ghost/content \
    TMPDIR=/tmp

WORKDIR /ghost
USER 65532:65532
VOLUME /ghost/content
EXPOSE 2368

ENTRYPOINT ["/usr/local/bin/node", \
    "--permission", \
    "--allow-fs-read=/ghost", \
    "--allow-fs-read=/tmp", \
    "--allow-fs-write=/ghost/content", \
    "--allow-fs-write=/tmp", \
    "--allow-addons", \
    "--allow-worker", \
    "--disable-proto=delete", \
    "--require=/ghost/addon-guard.js", \
    "/ghost/entrypoint.js"]
