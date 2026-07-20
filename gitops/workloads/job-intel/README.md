# job-intel deploy runbook

The `job-intel` pipeline (source + image: `github.com/dackota/job-intel`,
`ghcr.io/dackota/job-intel`) runs here as two workloads:

- **job-intel-db** — pgvector Postgres (StatefulSet + Longhorn PVC). One DB
  backs both Dagster's run/event storage and the app's tables + embeddings.
- **job-intel** — the Dagster stack (webserver + daemon + K8sRunLauncher) as a
  thin umbrella over the official Dagster Helm chart, plus app-owned
  HTTPRoute/Certificate for the Dagit UI at `jobs.dackota.com`.

ArgoCD picks both up automatically (each is a chart dir with a `config.yaml`
under `gitops/workloads/`). But three things are **git-invisible prerequisites**
— do them before/with the commit, consistent with this repo's out-of-band secret
convention (e.g. the change-tracking-dashboard PVC annotation).

## 1. Vendor the Dagster chart dependency

The `job-intel` umbrella chart depends on the upstream `dagster` chart. Like the
platform charts, vendor it as a committed `.tgz` (the repo's
`revendor-helm-charts.yaml` workflow follows the same pattern):

```sh
cd gitops/workloads/job-intel
helm dependency build     # writes charts/dagster-1.9.11.tgz + Chart.lock
git add charts/ Chart.lock
```

`job-intel-db` has no dependencies — nothing to vendor there.

## 2. Create the two Secrets by hand (never committed)

Pick a strong DB password once; reuse it in both places.

```sh
CTX=<your-kubectl-context>
kubectl --context "$CTX" create namespace job-intel --dry-run=client -o yaml | kubectl --context "$CTX" apply -f -

PGPW='<choose-a-strong-password>'

# (a) DB password — key MUST be `postgresql-password` (job-intel-db StatefulSet
#     AND the Dagster chart's postgresqlSecretName both read this key).
kubectl --context "$CTX" -n job-intel create secret generic job-intel-db \
  --from-literal=postgresql-password="$PGPW"

# (b) App env — DSN (with the same password) + Claude API key. The user-code
#     deployment and every K8sRunLauncher run pod inherit these.
kubectl --context "$CTX" -n job-intel create secret generic job-intel-app \
  --from-literal=JOB_INTEL_DB_DSN="postgresql://postgres:${PGPW}@job-intel-db.job-intel.svc.cluster.local:5432/jobintel" \
  --from-literal=ANTHROPIC_API_KEY="sk-ant-..."
```

> The namespace is created by the workloads ApplicationSet anyway, but making it
> first lets you pre-create the Secrets so pods don't crashloop waiting on them.

## 3. DNS

Point `jobs.dackota.com` at the same OCI LoadBalancer IP as the other apps
(`kubectl -n traefik get svc` → the LB external IP). cert-manager then issues the
`job-intel-tls` cert via HTTP-01 through the Gateway.

## Platform change already in this commit

`gitops/platform/traefik/values.yaml` gains a `certificateRefs` entry for
`job-intel-tls` (ns `job-intel`) so the shared `websecure` listener serves this
host's cert by SNI. The matching `ReferenceGrant` is rendered by this chart
(`templates/referencegrant.yaml`).

## Verify

```sh
kubectl --context "$CTX" -n job-intel get pods          # db, webserver, daemon, user-deployment Running
kubectl --context "$CTX" -n job-intel get certificate   # job-intel-tls -> Ready=True
curl -I https://jobs.dackota.com                        # Dagit UI over HTTPS
```

Then open the Dagit UI, materialize a partition of `daily_pipeline`, and watch
the K8sRunLauncher spin up a run pod. The daily schedule
(`daily_pipeline_schedule`) runs it at 07:00 UTC.

## Free-tier capacity note

This adds ~4 always-on pods (db, webserver, daemon, user-deployment) plus
ephemeral run pods. Requests are sized small, but if pods stay `Pending` on the
2-node A1 cluster, trim `dagster.dagsterDaemon` / `dagsterWebserver` requests in
`values.yaml` or lower `runLauncher` limits — that's the first knob to turn.
