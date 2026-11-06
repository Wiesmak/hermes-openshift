ARG UBI_IMAGE=registry.access.redhat.com/ubi9/ubi:9.8

FROM ${UBI_IMAGE} AS build_base
USER 0
RUN dnf -y --disablerepo='*' --enablerepo=ubi-9-baseos-rpms,ubi-9-appstream-rpms \
        --setopt=install_weak_deps=False install \
        ca-certificates curl-minimal git-core python3.11 tar gzip xz \
        gcc gcc-c++ make cmake libffi-devel libatomic \
    && dnf clean all
ENV PYTHONDONTWRITEBYTECODE=1 \
    CC=gcc CXX=g++ \
    HERMES_RUNTIME_DIR=/opt/hermes/tools
WORKDIR /opt/hermes
COPY build-support.sh /tmp/build-support.sh

FROM build_base AS init_build
# Official x86-64 binary and corresponding source from the same release.
RUN test "$(uname -m)" = x86_64 \
    && mkdir -p /out \
    && curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
        -o /out/catatonit https://github.com/openSUSE/catatonit/releases/download/v0.2.1/catatonit.x86_64 \
    && curl -fsSL --retry 3 --connect-timeout 15 --max-time 120 \
        -o /out/source.tar.xz https://github.com/openSUSE/catatonit/releases/download/v0.2.1/catatonit.tar.xz \
    && echo '8293951eaa7767fa411e3b89777bd01bc5e56db9ba6d145ad10cc4d05b01e961  /out/catatonit' | sha256sum -c - \
    && echo '9950425501af862e12f618bdc930ea755c46db6a16072a1462b4fc93b2bd59bc  /out/source.tar.xz' | sha256sum -c - \
    && tar -xOf /out/source.tar.xz catatonit-0.2.1/COPYING > /out/COPYING \
    && chmod 0755 /out/catatonit

FROM build_base AS upstream
ARG HERMES_RELEASE=v0.23.0
ARG HERMES_COMMIT=2bd378ed1b8d6bf2192cb26e0a55ff3091e6bd19
RUN /bin/sh /tmp/build-support.sh fetch "$HERMES_RELEASE" "$HERMES_COMMIT"

FROM upstream AS toolchain
# PM verifies each archive against the checked-out release's pm/lock.json.
# Chromium is an optional agent tool. The hosted Webapp runs in the client browser.
RUN python3.11 -c 'from pm import ensure; [ensure(name, explicit=True) for name in ("uv", "npm", "ffmpeg", "ripgrep")]' \
    && /bin/sh /tmp/build-support.sh tool-links
ENV PATH=/opt/hermes/bin:${PATH} HERMES_PYTHON=/opt/hermes/bin/python3

FROM toolchain AS frontends
ENV npm_config_install_links=false
RUN node apps/desktop/scripts/build-webapp.mjs \
    && node scripts/build/node-deps.mjs --source /opt/hermes --workspace ui-tui \
    && node scripts/build/tui.mjs --source /opt/hermes --out /out/tui \
    && mv apps/desktop/dist-webapp /out/webapp

FROM toolchain AS assembly
# Keep the previous Python feature selection, including the gateway's [web]
# dependencies (via [all]) and the collector's OTLP/HTTP exporter.
RUN python3 -m pm.build_env --source /opt/hermes --python /opt/hermes/bin/python3 \
        --cache /tmp/uv-cache --out /opt/hermes/.venv \
        --no-install-project --sealed --record-selection \
        --extra all --extra messaging --extra otlp --extra anthropic --extra bedrock \
        --extra azure-identity --extra google-chat --extra fal --extra documents \
    && /bin/sh /tmp/build-support.sh seal-pm

# Replace source frontends with packaged products. The Python Webapp listener
# shares the dashboard API and auth plugins, which stay in the image.
RUN rm -rf apps ui-tui web website tests tests-js nix packaging \
    && rm -f .venv/.lock pm-runtime/.lock
COPY --from=frontends /out/tui /opt/hermes/ui-tui
COPY --from=frontends /out/webapp /opt/hermes/apps/desktop/dist-webapp
COPY --from=frontends /opt/hermes/node_modules/typescript /opt/hermes/node_modules/typescript
COPY --chmod=0755 openshift-entrypoint.sh /opt/hermes/bin/openshift-entrypoint
ARG HERMES_RELEASE
ARG HERMES_COMMIT
RUN /bin/sh /tmp/build-support.sh assemble "$HERMES_RELEASE" "$HERMES_COMMIT"

FROM ${UBI_IMAGE} AS runtime
USER 0
RUN dnf -y --disablerepo='*' --enablerepo=ubi-9-baseos-rpms,ubi-9-appstream-rpms \
        --setopt=install_weak_deps=False install \
        ca-certificates git-core openssh-clients procps-ng libatomic libffi libstdc++ \
    && dnf clean all && rm -rf /var/cache/dnf \
    && install -d -m 0770 -g 0 /opt/data
COPY --from=assembly /opt/hermes /opt/hermes
COPY --from=assembly /out/image-provenance.json /etc/hermes/image-provenance.json
COPY --from=init_build /out/catatonit /usr/local/bin/catatonit
COPY --from=init_build /out/source.tar.xz /usr/share/licenses/catatonit/source.tar.xz
COPY --from=init_build /out/COPYING /usr/share/licenses/catatonit/COPYING

ARG HERMES_RELEASE=v0.23.0
ARG HERMES_COMMIT=2bd378ed1b8d6bf2192cb26e0a55ff3091e6bd19
LABEL org.opencontainers.image.title="Hermes Agent for OpenShift" \
      org.opencontainers.image.version="${HERMES_RELEASE}" \
      org.opencontainers.image.revision="${HERMES_COMMIT}" \
      org.opencontainers.image.source="https://github.com/NousResearch/hermes-agent"
ENV HERMES_HOME=/opt/data HOME=/opt/data \
    HERMES_WRITE_SAFE_ROOT=/opt/data \
    HERMES_RUNTIME_DIR=/opt/hermes/tools \
    HERMES_TUI_DIR=/opt/hermes/ui-tui \
    HERMES_WEBAPP_DIST=/opt/hermes/apps/desktop/dist-webapp \
    HERMES_PYTHON=/opt/hermes/.venv/bin/python \
    PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1 \
    PATH=/opt/hermes/.venv/bin:/opt/hermes/bin:/opt/hermes/node_modules/.bin:/opt/data/.local/bin:${PATH}

USER 1001:0
WORKDIR /opt/hermes
# Fail the build if a future lock changes the runtime ABI or required products.
RUN test -r "$HERMES_WEBAPP_DIST/index.html" \
    && test -r "$HERMES_TUI_DIR/dist/entry.js" \
    && python -c 'import sqlite3; assert sqlite3.sqlite_version_info >= (3, 51, 3), sqlite3.sqlite_version; db = sqlite3.connect(":memory:"); db.execute("CREATE VIRTUAL TABLE t USING fts5(x, tokenize=trigram)"); db.execute("INSERT INTO t VALUES (\x27hermes\x27)"); assert db.execute("SELECT count(*) FROM t WHERE t MATCH \x27erm\x27").fetchone() == (1,)' \
    && python -c 'import aiohttp, fastapi, uvicorn, uvloop, websockets, httptools; from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter' \
    && hermes --version && node --version && npm --version && npx --version \
    && tsc --version && rg --version \
    && ffmpeg -version >/dev/null && ffprobe -version >/dev/null \
    && catatonit -- /bin/true
EXPOSE 8443 9120
ENTRYPOINT ["/usr/local/bin/catatonit", "-g", "--", "/opt/hermes/bin/openshift-entrypoint"]
CMD ["gateway", "run"]
