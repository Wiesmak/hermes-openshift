#!/bin/sh
set -eu

operation=$1
shift

fetch_source() {
    HERMES_RELEASE=$1
    HERMES_COMMIT=$2
    printf '%s\n' "$HERMES_RELEASE" | grep -Eq '^v[0-9]{1,3}\.[0-9]{1,5}\.[0-9]{1,5}$'
    printf '%s\n' "$HERMES_COMMIT" | grep -Eq '^[a-f0-9]{40}$'
    git init -q /tmp/upstream
    git -C /tmp/upstream fetch --quiet --depth=1 https://github.com/NousResearch/hermes-agent.git "refs/tags/$HERMES_RELEASE"
    test "$(git -C /tmp/upstream rev-parse 'FETCH_HEAD^{commit}')" = "$HERMES_COMMIT"
    git -C /tmp/upstream archive --format=tar "$HERMES_COMMIT" > /tmp/hermes.tar
    tar -xf /tmp/hermes.tar
    rm -rf /tmp/upstream /tmp/hermes.tar
}

link_tools() {
    python3.11 - <<'PY'
from pathlib import Path
from shutil import which
from pm import env_for, installed_package

bin_dir = Path("/opt/hermes/bin")
bin_dir.mkdir(exist_ok=True)
for command, package in (
    ("python3", "python"), ("node", "node"), ("npm", "npm"),
    ("ffmpeg", "ffmpeg"), ("rg", "ripgrep"),
):
    (bin_dir / command).symlink_to(installed_package(package).binary)
(bin_dir / "ffprobe").symlink_to((bin_dir / "ffmpeg").resolve().with_name("ffprobe"))
(bin_dir / "npx").symlink_to(which("npx", path=env_for("npm", base_env={})["PATH"]))
PY
}

seal_pm() {
    python3 - <<'PY'
from pathlib import Path
from pm import stage_manager_runtime
from scripts.bundles.payload import seal_pm_runtime

root = Path("/opt/hermes")
python = (root / "bin/python3").resolve()
stage_manager_runtime(python=python, destination=root / "pm-runtime", project=root / "pm")
seal_pm_runtime(root, python)
PY
}

assemble_runtime() {
    HERMES_RELEASE=$1
    HERMES_COMMIT=$2
    mkdir -p node_modules/.bin /out
    ln -s ../typescript/bin/tsc node_modules/.bin/tsc
    printf 'docker\n' > .install_method
    python3 scripts/write_install_stamp.py --output install-stamp.json \
        --commit "$HERMES_COMMIT" --base-version "${HERMES_RELEASE#v}" \
        --display-version "${HERMES_RELEASE#v}" --distance 0 \
        --distribution docker --source openshift-ubi9 --update-mechanism external
    python3 - <<'PY'
import json
from pathlib import Path
import sysconfig

from pm.store import current_target
from scripts.build.agent import assemble
from scripts.build.inputs import AgentInputs, RESOURCE_ENV

root = Path("/opt/hermes")
environment = root / ".venv"
pm_runtime = root / "pm-runtime"
stamp_file = root / "install-stamp.json"
stamp = json.loads(stamp_file.read_text())
stamp["pmRuntime"] = str(pm_runtime)
stamp_file.write_text(json.dumps(stamp) + "\n")
# Use the shared offline assembler directly. The stock Docker wrapper
# assumes the legacy dashboard bundle is always present.
assemble(AgentInputs(
    project=root / "pyproject.toml", code=root, repo=".", placement="fixed",
    target=current_target(), python=environment / "bin/python",
    site_packages=Path(sysconfig.get_path("purelib", vars={"base": str(environment)})),
    environment=environment, tools=root / "tools", pm_runtime=pm_runtime,
    resources={name: root / name for name in RESOURCE_ENV},
    frontends={"tui": root / "ui-tui", "webapp": root / "apps/desktop/dist-webapp"},
    bin_dir="libexec",
), root)
for name in json.loads((root / "manifest.json").read_text())["runtime"]["commands"]:
    path = environment / "bin" / name
    path.unlink(missing_ok=True)
    path.symlink_to(f"../../libexec/{name}")
Path("/out/image-provenance.json").write_text(json.dumps({
    "schema": 1, "deployment_kind": "image", "manager": "docker",
    "image": "hermes-openshift", "version": stamp["baseVersion"],
    "revision": stamp["commit"],
}) + "\n")
PY
    chmod -R a+rX,go-w /opt/hermes
}

case "$operation" in
    fetch) fetch_source "$@" ;;
    tool-links) link_tools ;;
    seal-pm) seal_pm ;;
    assemble) assemble_runtime "$@" ;;
    *) echo "Unknown build operation: $operation" >&2; exit 2 ;;
esac
