#!/usr/bin/env python3
"""The Kubernetes manifests (deploy/kubernetes), run on a throwaway cluster.

    python3 tools/k8s_test.py              # build both images, create a kind cluster, test, delete it
    python3 tools/k8s_test.py --no-build   # use the images omnigate-test-control:k8s and omnigate-test-dataplane:k8s
    python3 tools/k8s_test.py --keep       # leave the cluster (kind delete cluster --name omnigate-test)

Needs docker, kind and kubectl on PATH. It creates a kind cluster named
omnigate-test (one node, in a container), loads the two images and a Python
image for the mock providers into it, and applies deploy/kubernetes exactly
as it is, through an overlay that only names the images and makes the data
planes poll faster. Then it checks, through `kubectl port-forward`:

  - both workloads become ready, as the user and with the file system the
    manifests ask for;
  - a request goes through a data plane to a mock provider and is billed;
  - a key made through the admin API works, and the control plane counts
    two data planes;
  - the control plane's pod is deleted: the data planes keep serving, and
    the pod that replaces it has the keys and the usage (the volume);
  - the data planes are replaced (a rollout): the new ones serve, and the
    control plane counts two again, not four;
  - a change to the ConfigMap is picked up without a restart.

What it does not check: an Ingress or load balancer in front (the Service is
reached by port-forward), TLS, more than one node, a real storage class, and
that no request fails while pods are replaced.

Standard library only (it imports tools/e2e.py for its HTTP helpers).
"""
import argparse
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from e2e import ROOT, call, jcall, wait_until  # noqa: E402

CLUSTER = "omnigate-test"
NS = "omnigate-test"
CONTEXT = "kind-" + CLUSTER
IMAGES = {"control": "omnigate-test-control:k8s", "dataplane": "omnigate-test-dataplane:k8s"}
MOCK_IMAGE = "python:3.12-alpine"
INTERNAL = "k8s-test-internal-token-0123456789abcdef"
ADMIN = "k8s-test-admin-token-0123456789abcdef"
KEY = "og-k8s-test-key-0001"
GATEWAY_PORT, CONTROL_PORT = 28080, 24000
GATEWAY, CONTROL = f"http://127.0.0.1:{GATEWAY_PORT}", f"http://127.0.0.1:{CONTROL_PORT}"
CHAT = {"model": "chat", "messages": [{"role": "user", "content": "hi"}]}

results = []
forwards = []


def check(name, ok, detail=None):
    results.append((name, bool(ok)))
    print(("  PASS  " if ok else "  FAIL  ") + name + ("" if ok or detail is None else f"   [{str(detail)[:500]}]"), flush=True)


def sh(*cmd, check_rc=True, timeout=900, stdin=None):
    r = subprocess.run(list(cmd), capture_output=True, text=True, timeout=timeout, input=stdin)
    if check_rc and r.returncode != 0:
        raise SystemExit(f"{' '.join(cmd[:6])} ... failed:\n{(r.stdout + r.stderr)[-3000:]}")
    return r


def kubectl(*args, **kw):
    return sh("kubectl", "--context", CONTEXT, "-n", NS, *args, **kw)


def config(extra_route=False):
    price = {"price_in_per_mtok": 100.0, "price_out_per_mtok": 300.0}
    up = lambda name, kind, port: {"name": name, "kind": kind, "base_url": f"http://mocks:{port}", "api_key_env": "MOCK_API_KEY"}  # noqa: E731
    routes = [
        # The first target always answers 503: every request fails over.
        {"model": "chat", "targets": [dict(upstream="mock-flaky", model="f", **price), dict(upstream="mock-ok", model="ok-1", **price)]},
        {"model": "claude", "targets": [dict(upstream="mock-anthropic", model="mock-claude", **price)]},
    ]
    if extra_route:
        routes.append({"model": "added-later", "targets": [dict(upstream="mock-ok", model="ok-1", **price)]})
    return {"keys": [{"name": "main", "key": KEY}],
            "upstreams": [up("mock-flaky", "openai", 9001), up("mock-ok", "openai", 9002), up("mock-anthropic", "anthropic", 9003)],
            "routes": routes}


MOCKS = """\
apiVersion: v1
kind: Service
metadata: {name: mocks}
spec:
  selector: {app: mocks}
  ports:
    - {name: flaky, port: 9001}
    - {name: openai, port: 9002}
    - {name: anthropic, port: 9003}
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: mocks}
spec:
  replicas: 1
  selector: {matchLabels: {app: mocks}}
  template:
    metadata: {labels: {app: mocks}}
    spec:
      containers:
        - name: mocks
          image: %s
          imagePullPolicy: IfNotPresent
          command: ["python", "/tools/mock_upstream.py"]
          env:
            - {name: MOCK_BIND, value: 0.0.0.0}
            - {name: PYTHONUNBUFFERED, value: "1"}
          volumeMounts: [{name: tools, mountPath: /tools}]
      volumes:
        - name: tools
          configMap: {name: mock-tools}
""" % MOCK_IMAGE

OVERLAY = """\
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: %s
resources:
  - base
images:
  - {name: ghcr.io/legatia/omnigate-control, newName: omnigate-test-control, newTag: k8s}
  - {name: ghcr.io/legatia/omnigate-dataplane, newName: omnigate-test-dataplane, newTag: k8s}
patches:
  - target: {kind: Deployment, name: omnigate-dataplane}
    patch: |-
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value: {name: OMNIGATE_POLL_MS, value: "300"}
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value: {name: OMNIGATE_FLUSH_MS, value: "200"}
""" % NS


def forward(service, local, remote):
    """`kubectl port-forward` to a Service, restarted by `reforward` when its pod goes away."""
    proc = subprocess.Popen(["kubectl", "--context", CONTEXT, "-n", NS, "port-forward", f"svc/{service}", f"{local}:{remote}"],
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    forwards.append((proc, service, local, remote))
    return proc


def reforward():
    """Port-forwards die with the pod they lead to: start them all again and wait until both answer."""
    old = list(forwards)
    forwards.clear()
    for proc, *_ in old:
        proc.terminate()
    for _, service, local, remote in old:
        forward(service, local, remote)
    return wait_until(lambda: call("GET", GATEWAY + "/healthz", timeout=3)[0] == 200 and call("GET", CONTROL + "/readyz", timeout=3)[0] == 200, 60, 0.5)


def admin(method, path, body=None):
    return jcall(method, CONTROL + path, key=ADMIN, body=body, timeout=15)


def chat(key=KEY, model="chat"):
    status, headers, body = jcall("POST", GATEWAY + "/v1/chat/completions", key=key, body=dict(CHAT, model=model), timeout=30)
    return status, headers, body


def metric(name):
    status, _, raw = call("GET", CONTROL + "/metrics", key=ADMIN, timeout=10)
    for row in raw.decode("utf-8", "replace").splitlines() if status == 200 else []:
        if row.startswith(name + " "):
            return float(row.split()[-1])
    return None


def requests_of(name):
    _, _, usage = admin("GET", "/admin/usage")
    for row in usage.get("keys", []) if isinstance(usage, dict) else []:
        if row.get("name") == name:
            return row.get("requests", 0)
    return 0


def pods(component):
    r = kubectl("get", "pods", "-l", f"app.kubernetes.io/component={component}", "-o", "json")
    return json.loads(r.stdout)["items"]


def ready(pod):
    return any(c.get("type") == "Ready" and c.get("status") == "True" for c in pod.get("status", {}).get("conditions", []))


def setup(work, build):
    for tool in ("docker", "kind", "kubectl"):
        if not shutil.which(tool):
            raise SystemExit(f"`{tool}` is not on PATH")
    if build:
        for name, image in IMAGES.items():
            print(f"building {image} ...", flush=True)
            sh("docker", "build", "-q", "-t", image, "-f", os.path.join(ROOT, name, "Dockerfile"), ROOT, timeout=3600)
    sh("docker", "pull", "-q", MOCK_IMAGE)
    sh("kind", "delete", "cluster", "--name", CLUSTER, check_rc=False)
    print("creating the cluster ...", flush=True)
    sh("kind", "create", "cluster", "--name", CLUSTER, "--wait", "180s")
    for image in list(IMAGES.values()) + [MOCK_IMAGE]:
        sh("kind", "load", "docker-image", "--name", CLUSTER, image)
    sh("kubectl", "--context", CONTEXT, "create", "namespace", NS)

    cfg = os.path.join(work, "omnigate.json")
    with open(cfg, "w", encoding="utf-8") as f:
        json.dump(config(), f, indent=2)
    kubectl("create", "configmap", "omnigate-config", f"--from-file=omnigate.json={cfg}")
    kubectl("create", "secret", "generic", "omnigate-control", f"--from-literal=OMNIGATE_INTERNAL_TOKEN={INTERNAL}",
            f"--from-literal=OMNIGATE_ADMIN_TOKEN={ADMIN}", "--from-literal=MOCK_API_KEY=mock-secret")
    kubectl("create", "secret", "generic", "omnigate-dataplane", f"--from-literal=OMNIGATE_INTERNAL_TOKEN={INTERNAL}", "--from-literal=MOCK_API_KEY=mock-secret")
    kubectl("create", "configmap", "mock-tools", f"--from-file={os.path.join(ROOT, 'tools', 'mock_upstream.py')}",
            f"--from-file={os.path.join(ROOT, 'tools', 'fastbind.py')}")
    kubectl("apply", "-f", "-", stdin=MOCKS)

    # The manifests as they are in the repository, under an overlay that names the images.
    shutil.copytree(os.path.join(ROOT, "deploy", "kubernetes"), os.path.join(work, "base"))
    with open(os.path.join(work, "kustomization.yaml"), "w", encoding="utf-8") as f:
        f.write(OVERLAY)
    kubectl("apply", "-k", work)


def describe():
    for what in ("pods", "pvc", "events"):
        print(f"--- {what} ---\n" + kubectl("get", what, "-o", "wide", check_rc=False).stdout[-4000:])
    for target in ("statefulset/omnigate-control", "deployment/omnigate-dataplane"):
        print(f"--- logs of {target} ---\n" + kubectl("logs", target, "--tail", "40", "--all-containers", check_rc=False).stdout[-4000:])


def checks(work):
    control = kubectl("rollout", "status", "statefulset/omnigate-control", "--timeout=300s", check_rc=False)
    dataplane = kubectl("rollout", "status", "deployment/omnigate-dataplane", "--timeout=300s", check_rc=False)
    mocks = kubectl("rollout", "status", "deployment/mocks", "--timeout=300s", check_rc=False)
    dps = pods("dataplane")
    check("the manifests apply, and the control plane, two data planes and the mock providers become ready",
          control.returncode == 0 and dataplane.returncode == 0 and mocks.returncode == 0 and len([p for p in dps if ready(p)]) == 2,
          (control.stdout + control.stderr + dataplane.stdout + dataplane.stderr)[-600:])
    if not (control.returncode == 0 and dataplane.returncode == 0):
        return

    # What the cluster made of the security settings: asked of the running container.
    who = kubectl("exec", "omnigate-control-0", "--", "sh", "-c", "id -u; touch /data/.probe && rm /data/.probe && echo writable", check_rc=False)
    claim = json.loads(kubectl("get", "pvc", "data-omnigate-control-0", "-o", "json").stdout)
    spec = dps[0]["spec"]["containers"][0]
    check("the control plane runs as user 10001 and can write to its volume, which is a bound claim; the data plane's root file system is read-only",
          who.stdout.split() == ["10001", "writable"] and claim["status"].get("phase") == "Bound"
          and spec["securityContext"].get("readOnlyRootFilesystem") is True and dps[0]["spec"]["securityContext"].get("runAsUser") == 10001,
          (who.stdout, who.stderr[-200:], claim["status"]))

    forward("omnigate", GATEWAY_PORT, 80)
    forward("omnigate-control", CONTROL_PORT, 4000)
    up = wait_until(lambda: call("GET", GATEWAY + "/healthz", timeout=3)[0] == 200 and call("GET", CONTROL + "/readyz", timeout=3)[0] == 200, 60, 0.5)
    listed = wait_until(lambda: (lambda r: r if r[0] == 200 else None)(jcall("GET", GATEWAY + "/v1/models", key=KEY, timeout=10)), 30, 0.5) or (0, {}, {})
    check("through the Services: the gateway and the control plane answer their probes, and the gateway lists the config's models",
          bool(up) and sorted(m.get("id") for m in listed[2].get("data", [])) == ["chat", "claude"], listed[2])

    status, headers, body = chat()
    text = (((body.get("choices") or [{}])[0]).get("message") or {}).get("content")
    billed = wait_until(lambda: requests_of("main") >= 1, 20, 0.5)
    check("a request goes through a data plane, fails over from the provider that is down to the next, and is billed by the control plane",
          status == 200 and text == "Hello from the mock upstream." and headers.get("x-omnigate-upstream") == "mock-ok" and bool(billed), (status, body, headers.get("x-omnigate-upstream")))

    status, _, created = admin("POST", "/admin/keys", {"name": "k8s-managed", "budget_usd": 5})
    secret = created.get("key", "")
    works = wait_until(lambda: chat(key=secret)[0] == 200, 20, 0.5)
    planes = wait_until(lambda: metric("omnigate_data_planes") == 2, 20, 0.5)
    check("a key made through the admin API works at the gateway; the control plane counts two data planes",
          status == 201 and bool(works) and bool(planes), (status, metric("omnigate_data_planes")))

    # The control plane's pod goes away. The data planes serve from the config they hold; its replacement has the volume.
    before = requests_of("main") + requests_of("k8s-managed")
    kubectl("delete", "pod", "omnigate-control-0", "--wait=false")
    wait_until(lambda: call("GET", CONTROL + "/healthz", timeout=2)[0] != 200, 30, 0.3)
    during = [chat()[0] for _ in range(5)] + [chat(key=secret)[0]]
    back = kubectl("rollout", "status", "statefulset/omnigate-control", "--timeout=300s", check_rc=False)
    again = reforward()
    _, _, keys = admin("GET", "/admin/keys")
    kept = [k.get("name") for k in keys.get("keys", [])] if isinstance(keys, dict) else []
    counted = wait_until(lambda: requests_of("main") + requests_of("k8s-managed") >= before + 6, 40, 0.5)
    check("with the control plane's pod deleted the data planes keep answering; its replacement has the keys and the usage from before, and is handed the usage made meanwhile",
          during == [200] * 6 and back.returncode == 0 and bool(again) and "k8s-managed" in kept and bool(counted) and chat(key=secret)[0] == 200,
          (during, back.stderr[-200:], kept, before, requests_of("main") + requests_of("k8s-managed")))

    # The data planes are replaced. The old ones say that they stop, so they are not counted any more.
    old = sorted(p["metadata"]["name"] for p in pods("dataplane"))
    kubectl("rollout", "restart", "deployment/omnigate-dataplane")
    rolled = kubectl("rollout", "status", "deployment/omnigate-dataplane", "--timeout=300s", check_rc=False)
    gone = wait_until(lambda: not (set(old) & {p["metadata"]["name"] for p in pods("dataplane")}), 90, 1)
    again = reforward()
    serving = wait_until(lambda: chat(key=secret)[0] == 200, 30, 0.5)
    # (Well inside the half minute after which a data plane that only disappeared is forgotten.)
    two = wait_until(lambda: metric("omnigate_data_planes") == 2, 12, 0.5)
    check("after a rollout of the data planes the new pods serve, with the managed key, and the control plane counts two data planes again, not four",
          rolled.returncode == 0 and bool(gone) and bool(again) and bool(serving) and bool(two), (rolled.stderr[-200:], metric("omnigate_data_planes")))

    # A change to the ConfigMap reaches the mounted file after a while (the kubelet syncs it), and then the gateway.
    cfg = os.path.join(work, "omnigate.json")
    with open(cfg, "w", encoding="utf-8") as f:
        json.dump(config(extra_route=True), f, indent=2)
    rendered = kubectl("create", "configmap", "omnigate-config", f"--from-file=omnigate.json={cfg}", "--dry-run=client", "-o", "yaml").stdout
    kubectl("apply", "-f", "-", stdin=rendered)
    started = time.time()
    seen = wait_until(lambda: "added-later" in [m.get("id") for m in (jcall("GET", GATEWAY + "/v1/models", key=KEY, timeout=10)[2] or {}).get("data", [])], 240, 2)
    check("a route added to the ConfigMap is served without restarting anything", bool(seen) and chat(model="added-later")[0] == 200, f"not after {time.time() - started:.0f}s")
    if seen:
        print(f"        (the change arrived after {time.time() - started:.0f}s)")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--no-build", action="store_true", help="use the images that are there")
    ap.add_argument("--keep", action="store_true", help="leave the cluster running")
    args = ap.parse_args()
    work = tempfile.mkdtemp(prefix="omnigate-k8s-")
    started = time.time()
    try:
        setup(work, not args.no_build)
        checks(work)
    finally:
        if any(not ok for _, ok in results) or not results:
            describe()
        for proc, *_ in forwards:
            proc.terminate()
        if args.keep:
            print(f"\nleft running: kind cluster {CLUSTER} (kubectl --context {CONTEXT} -n {NS} get pods)")
        else:
            sh("kind", "delete", "cluster", "--name", CLUSTER, check_rc=False)
        shutil.rmtree(work, ignore_errors=True)
    failed = [n for n, ok in results if not ok]
    print(f"\n{len(results) - len(failed)}/{len(results)} Kubernetes checks passed in {time.time() - started:.0f}s")
    for n in failed:
        print("  failed:", n)
    sys.exit(1 if failed or not results else 0)


if __name__ == "__main__":
    main()
