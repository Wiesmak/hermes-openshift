"""Submit one build per stable release and pinned build configuration."""
import hashlib
import json
import os
from pathlib import Path
import re
import ssl
from urllib.error import HTTPError
from urllib.parse import urlsplit
from urllib.request import Request, urlopen

UPSTREAM = "https://api.github.com/repos/NousResearch/hermes-agent"
SERVICE_ACCOUNT = Path("/var/run/secrets/kubernetes.io/serviceaccount")


def request(url, headers, *, body=None, context=None):
    if body is not None:
        headers = {**headers, "Content-Type": "application/json"}
        body = json.dumps(body).encode()
    with urlopen(Request(url, data=body, headers=headers), timeout=30, context=context) as reply:
        return json.load(reply)


def github(path):
    return request(UPSTREAM + path, {"Accept": "application/vnd.github+json"})


def latest_release():
    release = github("/releases/latest")
    tag = release["tag_name"]
    if release["draft"] or release["prerelease"] or not re.fullmatch(
        r"v[0-9]{1,3}\.[0-9]{1,5}\.[0-9]{1,5}", tag
    ):
        raise ValueError(f"Expected a stable Hermes release, got {tag!r}")
    target = github(f"/git/ref/tags/{tag}")["object"]
    # GitHub supports both lightweight and annotated tags.
    for _ in range(5):
        sha = target["sha"]
        if not re.fullmatch(r"[a-f0-9]{40}", sha):
            raise ValueError("Invalid upstream object SHA")
        if target["type"] == "commit":
            return tag, sha
        if target["type"] != "tag":
            break
        target = github(f"/git/tags/{sha}")["object"]
    raise ValueError(f"Tag {tag} did not resolve to a commit")


def build_run(tag, upstream_commit):
    recipe = os.environ["RECIPE_REPOSITORY"]
    recipe_commit = os.environ["RECIPE_COMMIT"]
    base = os.environ["UBI_IMAGE"]
    image = os.environ["IMAGE_REPOSITORY"]
    repo_url = urlsplit(recipe)
    if (repo_url.scheme != "https" or not repo_url.hostname or repo_url.username is not None
            or repo_url.query or repo_url.fragment):
        raise ValueError("RECIPE_REPOSITORY must be a public HTTPS Git URL")
    if not re.fullmatch(r"[a-f0-9]{40}", recipe_commit):
        raise ValueError("RECIPE_COMMIT must be a full Git commit SHA")
    if not re.fullmatch(r"[a-z0-9./:_-]+@sha256:[a-f0-9]{64}", base):
        raise ValueError("UBI_IMAGE must be a digest-pinned OCI image")
    if not re.fullmatch(r"[a-z0-9.:-]+/[a-z0-9./_-]+", image):
        raise ValueError("IMAGE_REPOSITORY must include a registry and omit any tag or digest")
    identity = hashlib.sha256(json.dumps([tag, upstream_commit, recipe, recipe_commit, base, image]).encode())
    suffix = identity.hexdigest()[:16]
    name = "hermes-" + tag.replace(".", "-") + "-" + suffix
    ref = f"{image}:{tag}-{suffix}"
    params = {
        "release": tag,
        "upstream-commit": upstream_commit,
        "recipe-repository": recipe,
        "recipe-commit": recipe_commit,
        "ubi-image": base,
        "image": ref,
    }
    return {
        "apiVersion": "tekton.dev/v1",
        "kind": "PipelineRun",
        "metadata": {"name": name, "labels": {"app.kubernetes.io/name": "hermes-build"}},
        "spec": {
            "pipelineRef": {"name": "hermes-build"},
            "taskRunTemplate": {
                "serviceAccountName": "pipeline",
                "podTemplate": {"nodeSelector": {"kubernetes.io/arch": "amd64"}},
            },
            "workspaces": [
                {"name": "source", "volumeClaimTemplate": {"spec": {
                    "accessModes": ["ReadWriteOnce"],
                    "resources": {"requests": {"storage": "256Mi"}},
                }}},
                {"name": "registry-auth", "secret": {"secretName": "hermes-registry"}},
            ],
            "timeouts": {"pipeline": "1h30m"},
            "params": [{"name": key, "value": value} for key, value in params.items()],
        },
    }


def main():
    run = build_run(*latest_release())
    name = run["metadata"]["name"]
    namespace = (SERVICE_ACCOUNT / "namespace").read_text().strip()
    token = (SERVICE_ACCOUNT / "token").read_text().strip()
    tls = ssl.create_default_context(cafile=str(SERVICE_ACCOUNT / "ca.crt"))
    url = f"https://kubernetes.default.svc/apis/tekton.dev/v1/namespaces/{namespace}/pipelineruns"
    headers = {"Authorization": f"Bearer {token}"}
    try:
        request(url, headers, body=run, context=tls)
    except HTTPError as error:
        if error.code != 409:
            raise
        current = request(f"{url}/{name}", headers, context=tls)
        condition = next((item for item in current.get("status", {}).get("conditions", [])
                          if item.get("type") == "Succeeded"), {})
        if condition.get("status") == "False":
            raise SystemExit(f"{name} failed ({condition.get('reason')}). Inspect the logs before retrying.")
        print(f"{name} already exists ({condition.get('reason', 'pending')})")
    else:
        print(f"Submitted {name}")


if __name__ == "__main__":
    main()
