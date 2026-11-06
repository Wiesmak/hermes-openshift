# Hermes Agent v0.23.0 on OpenShift

This recipe builds a Linux amd64 UBI 9 image for running Hermes Agent on OpenShift. Its default `gateway run` command starts the gateway API on port 8443 and, when enabled in Hermes configuration, serves the Desktop Webapp on port 9120 from the same process. The image supports OTLP telemetry; a deployment can use an OpenTelemetry Collector sidecar with appropriate receiver and exporter configuration.

## Image contents and behavior

| Area | Description |
| --- | --- |
| Browser UI | Builds the Desktop Webapp with upstream's `apps/desktop/scripts/build-webapp.mjs` and includes the shared Python dashboard API and authentication plugins. The image serves the Webapp on port 9120 when enabled; it does not bundle the classic dashboard or start its 9119 listener. |
| Startup | Catatonit v0.2.1 runs as PID 1 and forwards signals to the gateway process group. The entrypoint starts the default profile explicitly so a persisted UI selection cannot redirect the host gateway into a named profile. It initializes `SOUL.md` when absent and synchronizes bundled skills. Other CLI commands retain upstream profile behavior. |
| OpenShift | Stores home and persistent data in `/opt/data` and supports an SCC-assigned UID. The gateway needs writable storage there and writable `/tmp`. If `API_SERVER_KEY` is supplied in the environment, startup rejects an assignment in the PVC's `.env` that could override it. |
| SQLite | Uses the locked standalone Python's SQLite, which reports 3.53.1 on amd64 for this release, above the 3.51.3 WAL-reset fix. The Dockerfile checks the actual runtime library and FTS5 trigram queries. |
| Dependencies | Uses the tagged release's PM, Python and npm locks and the shared offline assembler. Includes Python extras for messaging and OTLP, the TUI, TypeScript, Node/npm, ripgrep and FFmpeg. Compiler tools, build caches, npm workspaces and the optional agent-controlled Chromium browser are excluded from the final image. The hosted Webapp runs in the user's browser. |
| Provenance | Resolves the release tag to the expected commit before executing its build recipes. The upstream install stamp records the released version and commit, and marks image updates as externally managed. |

For this release the PM artifacts are Python 3.14.9+20261021, uv 0.13.5, Node 26.12.1, npm 12.0.2, FFmpeg 9.0.1 and ripgrep 15.2.0. The same lock selects newer versions on future builds. The UBI base supplies glibc, libgcc, libstdc++, libatomic, libffi, CA trust and the system utilities. Public UBI RPM repositories supply OS dependencies. The UBI digest pins the base layers, while those RPM repositories still receive updates.

## Build once with Podman

Run from this directory in a Linux shell or Podman machine workflow.

```sh
podman build -t localhost/hermes-openshift:v0.23.0 .
podman run --rm --user 12345:0 --cap-drop=all \
  --security-opt no-new-privileges localhost/hermes-openshift:v0.23.0 --version
```

The local command uses the default UBI 9.8 tag and the exact v0.23.0 source SHA. For the CI base pin, resolve the index digest from an approved registry or mirror.

```sh
skopeo inspect --raw docker://registry.access.redhat.com/ubi9/ubi:9.8 > /tmp/ubi9-index.json
skopeo manifest-digest /tmp/ubi9-index.json
```

Use `registry.access.redhat.com/ubi9/ubi@sha256:…` as `UBI_IMAGE` below. You can also pass it locally with `--build-arg UBI_IMAGE=...`.

## Set up automatic builds

1. Commit this directory's contents at the root of a public HTTPS Git repository. Set `RECIPE_REPOSITORY` and the full `RECIPE_COMMIT` in `ci/discovery.yaml`. Commit or otherwise retain this cluster configuration separately from the recipe commit it points at.
2. Set `UBI_IMAGE` to your pinned base and `IMAGE_REPOSITORY` to a registry repository without a tag. Quay example `quay.io/gerardgajda/hermes-openshift`. For the integrated registry, use `image-registry.openshift-image-registry.svc:5000/<project>/<image>` with credentials authorized to push there.
3. Use a dedicated CI project with OpenShift Pipelines 1.21, the cluster resolver, a default dynamically provisioned RWO storage class, and an amd64 worker. Confirm that the shipped tasks exist and that your CI namespace's `pipeline` service account is available. The builder needs outbound access to GitHub, the UBI registry and RPM CDN, npm, PyPI and the upstream PM artifact hosts. Allow memory for the Vite build and node ephemeral storage for the Buildah stages and VFS layers. The PVC only transfers the recipe between tasks.

```sh
oc -n openshift-pipelines get task git-clone buildah
oc -n hermes-ci get serviceaccount pipeline
oc -n hermes-ci create secret generic hermes-registry \
  --type=kubernetes.io/dockerconfigjson \
  --from-file=.dockerconfigjson=/path/to/registry-auth.json
oc -n hermes-ci apply -k ci
oc -n hermes-ci create job --from=cronjob/hermes-release-discovery hermes-release-now
oc -n hermes-ci logs job/hermes-release-now
oc -n hermes-ci get pipelineruns
```

Inspect the run with `tkn -n hermes-ci pipelinerun logs <run> -f` or the OpenShift console. The PipelineRun results `IMAGE_URL` and `IMAGE_DIGEST` identify the pushed image. After the first run succeeds, set `suspend: false` in `ci/discovery.yaml` and reapply.

The hourly job polls GitHub's latest stable release, resolves its annotated or lightweight tag, and creates a deterministically named PipelineRun for that release SHA, recipe revision, base and destination. It follows the newest stable release at poll time and does not backfill releases superseded between polls. Keep the current release's PipelineRun outside any aggressive pruning policy so it remains the deduplication record. A failed run stays visible for diagnosis. After fixing the failure, delete that failed PipelineRun and let discovery submit it again. If a push succeeded before the run failed, inspect the existing registry tag and digest before retrying. Use repository-side tag immutability if offered by your registry.

Both shipped tasks use the operator-provisioned `pipeline` account in the CI project. Red Hat ships Buildah for that account and its configured build SCC. The catalog Git task can also specify a fixed UID. Stock `restricted-v2` alone is not a supported promise for these CI tasks. If cluster policy requires it for every CI pod, this pipeline requires a separately qualified Buildah configuration before use. This package grants no SCC and requires no runtime permissions for CI.

## Deploy on OpenShift

For an operator-managed `HermesInstance`, use the pushed digest in `spec.image` and provide persistent storage at `/opt/data`, writable `/tmp`, and a Secret for the gateway API key. Set `spec.shareProcessNamespace: false` so Catatonit owns PID 1 in the Hermes container. For the agent's `spec.security.podSecurityContext` and `containerSecurityContext` overrides, omit fixed UID, GID and fsGroup values. Set `runAsNonRoot: true`, `allowPrivilegeEscalation: false`, drop `ALL` capabilities and use `RuntimeDefault` seccomp. PVC files must be writable by the SCC-assigned identity. When supplying `API_SERVER_KEY` through the environment, do not also assign it in `/opt/data/.env`.

To enable the Webapp, merge the following into the Hermes configuration and use the deployment's public URL:

```yaml
webapp:
  enabled: true
  host: 0.0.0.0
  port: 9120
  public_url: https://hermes.example.com
```

Configure a Hermes dashboard sign-in provider for the Webapp. The bundled basic provider accepts `HERMES_DASHBOARD_BASIC_AUTH_USERNAME`, `HERMES_DASHBOARD_BASIC_AUTH_PASSWORD_HASH` and `HERMES_DASHBOARD_BASIC_AUTH_SECRET` from an OpenShift Secret. Set `dashboard.trusted_proxies` for the actual reverse proxy if it supplies forwarded headers. Point a ClusterIP Service at numeric target port `9120` on the Hermes pod and forward the Webapp route there. The gateway API uses port 8443 for its Service and probes. Configure a Collector and telemetry settings as needed by the deployment.

```sh
oc -n hermes get pod hermes-0 -o jsonpath='{.metadata.annotations.openshift\.io/scc}'
oc -n hermes exec hermes-0 -c hermes -- cat /proc/1/comm
oc -n hermes exec hermes-0 -c hermes -- hermes --profile default webapp --status
```

## Verification

The release commit, Catatonit checksums, locked PM tools, sealed Python dependency selection, offline assembly, runtime imports, SQLite trigram query and upstream frontend builds were checked in the workspace. Kustomize rendered the manifests, and the release poller resolved the live v0.23.0 tag and generated a deterministic PipelineRun. The workspace blocked the gateway Unix control socket during a local smoke run. The UBI RPM install, full image build, registry push and SCC admission still require a container engine or cluster. Run the first PipelineRun manually before enabling the schedule.

- [Hermes v0.23.0 release](https://github.com/NousResearch/hermes-agent/releases/tag/v0.23.0)
- [Hermes v0.23.0 Dockerfile](https://github.com/NousResearch/hermes-agent/blob/v0.23.0/Dockerfile)
- [Hermes Webapp configuration](https://github.com/NousResearch/hermes-agent/blob/v0.23.0/website/docs/user-guide/configuration.md#webapp)
- [SQLite WAL-reset fix](https://sqlite.org/wal.html#walresetbug)
- [OpenShift Pipelines shipped tasks](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.21/html/creating_cicd_pipelines/remote-pipelines-tasks-resolvers)
- [Red Hat Buildah security options](https://docs.redhat.com/en/documentation/red_hat_openshift_pipelines/1.21/html/securing_openshift_pipelines/unprivileged-building-of-container-images-using-buildah)
