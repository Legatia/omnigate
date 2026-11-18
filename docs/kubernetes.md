# Kubernetes

Plain manifests for running omnigate on a Kubernetes cluster are in
[`deploy/kubernetes`](../deploy/kubernetes). They are the Compose setup
([Deployment](deployment.md)) in Kubernetes terms, without the TLS proxy:
bring your own Ingress, Gateway or load balancer.

- [What the manifests create](#what-the-manifests-create)
- [Installing](#installing)
- [Reaching it](#reaching-it)
- [Changing the configuration](#changing-the-configuration)
- [Upgrading](#upgrading)
- [What to know before relying on it](#what-to-know-before-relying-on-it)
- [What has been tested](#what-has-been-tested)

## What the manifests create

| Object | What it is |
|---|---|
| StatefulSet `omnigate-control`, 1 replica | The control plane, with a 5 GiB volume claim at `/data` for the ledger, managed keys, jobs, payments and the audit log. **Exactly one replica**: two control planes would each keep a ledger of their own. |
| Service `omnigate-control`, port 4000 | The admin API, the dashboard and what the data planes call. ClusterIP: nothing outside the cluster reaches it, and nothing should without an authenticating proxy in front. |
| Deployment `omnigate-dataplane`, 2 replicas | The data planes, which clients talk to. Any number; they share each key's rate limit through the control plane ([Operations](operations.md)). |
| Service `omnigate`, port 80 | The gateway, in plain HTTP. ClusterIP: put your Ingress or load balancer in front, with TLS. |
| PodDisruptionBudget `omnigate-dataplane` | At least one data plane stays up while nodes are drained. |

Both run as user 10001 without privileges, with all capabilities dropped
and the default seccomp profile; the data plane's root file system is
read-only. Neither mounts a service account token: omnigate talks to no
cluster API. Both set `enableServiceLinks: false`: Kubernetes would
otherwise hand every pod a variable `OMNIGATE_CONTROL_PORT=tcp://...` for
the Service of that name, which is the variable the control plane reads its
port from. Keep that line if you write manifests of your own. Each container has a 1 GiB memory limit, and the data plane
gets the same memory budgets as in `compose.yaml`
([Memory limits](deployment.md#memory-limits)).

You create three objects yourself, because they hold your secrets and your
configuration:

| Object | What goes in it |
|---|---|
| Secret `omnigate-control` | The variables of [`.env.control.example`](../.env.control.example): `OMNIGATE_INTERNAL_TOKEN`, `OMNIGATE_ADMIN_TOKEN`, media provider keys, webhook secrets, bucket credentials. |
| Secret `omnigate-dataplane` | The variables of [`.env.dataplane.example`](../.env.dataplane.example): the same `OMNIGATE_INTERNAL_TOKEN` and the keys of the text providers the config names. Nothing else: this is the process the internet reaches. |
| ConfigMap `omnigate-config` | One key, `omnigate.json`: [the configuration](configuration.md). |

## Installing

```sh
kubectl create namespace omnigate

kubectl -n omnigate create secret generic omnigate-control  --from-env-file=.env.control
kubectl -n omnigate create secret generic omnigate-dataplane --from-env-file=.env.dataplane
kubectl -n omnigate create configmap omnigate-config --from-file=omnigate.json=config/omnigate.json

kubectl -n omnigate apply -k deploy/kubernetes
kubectl -n omnigate rollout status statefulset/omnigate-control
kubectl -n omnigate rollout status deployment/omnigate-dataplane
```

The two `.env` files are the ones the Compose setup uses
([Deployment](deployment.md#compose-with-tls)); `--from-env-file` reads
`NAME=value` lines and skips comments. Keys given in the config as raw
values (`"key": "..."`) would sit in the ConfigMap in plain text: give keys
as `key_sha256`, or make them through the admin API.

The manifests name the images of one release
(`ghcr.io/legatia/omnigate-control:1.2.0` and `-dataplane:1.2.0`). To run
another version or images you built, put a `kustomization.yaml` of your own
next to a copy of the directory:

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: omnigate
resources:
  - kubernetes        # your copy of deploy/kubernetes
images:
  - name: ghcr.io/legatia/omnigate-control
    newTag: 1.2.0
  - name: ghcr.io/legatia/omnigate-dataplane
    newTag: 1.2.0
```

## Reaching it

- **The gateway**: point an Ingress, a Gateway route or a `LoadBalancer`
  Service at Service `omnigate`, port 80, and terminate TLS there. Streamed
  answers need a proxy that does not buffer responses and does not cut
  connections that are quiet for a while; set its read timeout above the
  gateway's stream idle timeout
  ([Configuration](configuration.md)).
- **The dashboard and the admin API**:
  `kubectl -n omnigate port-forward svc/omnigate-control 4000:4000`, then
  <http://localhost:4000>. Do not publish this Service as it is. If you put
  a proxy in front of it, set `OMNIGATE_TRUST_FORWARDED=1` on the control
  plane only when that proxy is the only way in and writes
  `X-Forwarded-For` itself ([Security](security.md)).
- **The top-up page and media job URLs** are served by the gateway, so
  `media.public_base_url` in the config is the address of your Ingress.

## Changing the configuration

Replace the ConfigMap; nothing needs a restart:

```sh
kubectl -n omnigate create configmap omnigate-config --from-file=omnigate.json=config/omnigate.json \
  --dry-run=client -o yaml | kubectl -n omnigate apply -f -
```

The kubelet brings the new file into the pod after a while (up to about a
minute, depending on the cluster), the control plane notices it within two
seconds of that, and the data planes follow at their next poll. A config
that does not load is refused and the one in force stays; the control
plane's log says why.

A changed Secret is different: environment variables are read when a
container starts, so restart the workload that uses it
(`kubectl -n omnigate rollout restart ...`).

## Upgrading

Read [Upgrading](upgrading.md) for the version first. Then change the image
tags and apply: control plane first, as everywhere.

```sh
kubectl -n omnigate set image statefulset/omnigate-control control=ghcr.io/legatia/omnigate-control:<version>
kubectl -n omnigate rollout status statefulset/omnigate-control
kubectl -n omnigate set image deployment/omnigate-dataplane dataplane=ghcr.io/legatia/omnigate-dataplane:<version>
```

While the control plane's pod is replaced the data planes keep serving from
the config they hold and keep the usage they could not hand over, in
memory and in their spool, until it is back
([Operations](operations.md)). The data planes are replaced one at a time
with none unavailable (`maxUnavailable: 0`); each one that stops finishes
the requests it has, hands over its usage and tells the control plane that
it is gone.

Back up the control plane's volume as [Backups](deployment.md#backups)
says; the files are the same.

## What to know before relying on it

- **The data plane's `/data` is an `emptyDir`.** It holds the cached config
  and the usage spool, and lives as long as the pod. A pod that is removed
  hands its usage over as it stops; usage it could not hand over because
  the control plane was away at that very moment is lost with the pod. If
  that matters to you, run the data planes as a StatefulSet with a volume
  claim each.
- **A new data-plane pod needs the control plane once.** It has no cached
  config, so it answers `503` until its first sync. Its readiness probe is
  `/healthz`, which says the process is up, not that it has a config: if
  the control plane is down while data planes are being replaced, new pods
  receive traffic they cannot serve. Do not roll the data planes while the
  control plane is down.
- **The control plane is a single pod.** While it is being replaced or
  moved, the admin API, the dashboard, media jobs and payments are
  unavailable; text requests are not affected.
- **No NetworkPolicy is included.** The internal token is what keeps other
  pods out of the control plane's internal endpoints. A policy that lets
  only the data-plane pods reach port 4000 is a good addition; it depends
  on your network plugin.

## What has been tested

[`tools/k8s_test.py`](../tools/k8s_test.py) runs in CI on every push, on a
one-node [kind](https://kind.sigs.k8s.io) cluster inside the runner. It
builds both images from the commit, applies `deploy/kubernetes` unchanged
(through an overlay that only names those images and makes the data planes
poll faster), and checks:

- both workloads become ready; the control plane runs as user 10001 and
  can write to its volume;
- a request goes through a data plane to a mock provider, fails over, and
  is billed;
- a key made through the admin API works, and the control plane counts two
  data planes;
- with the control plane's pod deleted, the data planes keep answering;
  the pod that replaces it has the keys and the usage, and is handed the
  usage made meanwhile;
- after a rollout of the data planes the new pods serve, and the control
  plane counts two data planes again;
- a route added to the ConfigMap is served without a restart.

Its first two runs (18 November 2026) were of the same manifests and test:
the first failed, the second passed. The log of the first could not be
read, so which step or check failed is not known; expect the test, not
necessarily the manifests, to have a timing-dependent check until that is
found.

**Not tested**: an Ingress or load balancer in front (the test reaches the
Services through `kubectl port-forward`), TLS, more than one node, a
storage class other than kind's local one, a managed Kubernetes service,
node drains, and whether any request fails while pods are replaced. Nobody
has run these manifests in production.
