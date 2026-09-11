# Lab 03 — Running the Multi-Service App on Kubernetes (KinD)

## Objective

Translate the Lab 02 Docker Compose stack onto Kubernetes, using KinD (Kubernetes in Docker) on the same Ubuntu host. This is a first hands-on Kubernetes lab — the theory is already there; this is where it becomes muscle memory.

**Long-term direction (not part of this lab):** the manifests built here are what a later AWS/Terraform lab will point at a real EKS cluster instead of KinD, and what a GitHub Actions lab will apply automatically on every push. Getting these right now pays off twice.

---

## Why this lab is split into sub-labs

Kubernetes has meaningfully more moving parts than Docker Compose — a Service with a wrong selector, a misconfigured probe, and a DNS typo all present the same symptom from the outside ("not ready"). Splitting into sub-labs, each isolating one new concept on the smallest possible slice of the app before adding more, follows the exact principle Lab 02 already used. Each sub-lab has its own checkpoint — don't move to the next until the current one's verification passes and actually makes sense to you, not just runs.

| Sub-lab       | Focus                                                              | New K8s concepts                                                                                                    |
| ------------- | ------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------- |
| 3.1           | KinD cluster (2 workers) + core object literacy, toy examples only | Cluster, Node, Pod, Deployment, Service, Namespace, kubectl                                                         |
| 3.2           | First real service: Postgres + one API                             | ConfigMap, Secret, PVC, init containers, probes                                                                     |
| 3.3           | Complete the translation + entry point                             | Remaining services, Ingress + ingress-nginx (successor to edge-proxy)                                               |
| 3.4           | The scaling payoff                                                 | Replicas, Service load-balancing, rolling updates — revisiting Lab 02's round-robin problem                         |
| 3.5           | Batch & scheduled work                                             | Job, CronJob — a real heartbeat-cleanup task added to the app                                                       |
| 3.6 (stretch) | Hardening                                                          | NetworkPolicy, resource requests/limits, StatefulSet for Postgres (real, not conceptual), HPA with a load-generator |

---

## Environment

| Role          | Hostname                      | IP              | OS            | Software                                |
| ------------- | ----------------------------- | --------------- | ------------- | --------------------------------------- |
| KinD host     | ubuntuserver1.ssa.veeam.local | 172.31.17.182   | Ubuntu Server | Docker Engine (Lab 02) + kubectl + kind |
| Control point | Windows workstation           | 172.24.209.0/24 | Windows       | SSH client + browser                    |

No new VM — KinD runs Kubernetes' control-plane and worker components as Docker containers on top of the existing Docker Engine.

Check free resources first (`free -h`); the plan assumes Lab 02's Compose stack is stopped while this lab is in progress, and the KinD cluster itself now runs **3 node-containers** (1 control-plane + 2 workers) instead of 1, which costs a bit more RAM than the original single-worker plan — worth confirming there's headroom before starting.

---

## Decisions locked in for this lab

* **Multi-node KinD cluster from the start** (1 control-plane + 2 workers) — revised from the original single-worker plan. Free to do in KinD, and it makes Pod-spread across nodes visible from Sub-lab 3.1 onward instead of being trivial with only one worker.
* **Declarative manifests (`kubectl apply -f`) as the primary practice from Sub-lab 3.2 onward.** Sub-lab 3.1 deliberately starts imperative (`kubectl run`, `kubectl expose`) purely to see the raw mechanism, then rebuilds the same thing as YAML.
* **One namespace for this app** (`multi-service-app`), not default.
* **Images loaded directly into KinD** via `kind load docker-image`, not pushed to a registry — a KinD-specific shortcut, flagged as something that won't exist once a registry (GitHub Actions lab) or a real cloud cluster enters the picture.
* **Init containers replace `depends_on: condition: service_healthy`** for Postgres-dependent services — Compose's `depends_on` has no Deployment equivalent; this is the idiomatic replacement, introduced in Sub-lab 3.2.
* **A small cleanup script gets added to the app itself** (deletes heartbeat rows older than N minutes), specifically so Jobs/CronJobs have a genuine home in Sub-lab 3.5 rather than an invented example.
* **StatefulSet for Postgres gets actually implemented in Sub-lab 3.6**, not just discussed — promoted from "optional/conceptual" in earlier planning to a real, built exercise.
* **Ingress deferred to Sub-lab 3.3**, not attempted alongside the first services.
* **TLS, RBAC, and CRDs/Operators deferred** — RBAC gets a brief optional mention in 3.6; Operators get a one-line pointer as "how this is often done for real" without being built.

---

## Concept map: Docker Compose (Lab 02) → Kubernetes (Lab 03)

| Lab 02 (Docker Compose)                  | Lab 03 (Kubernetes)                         | Notes                                                                                               |
| ---------------------------------------- | ------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| services: entry                          | Deployment                                  | manages a set of replica Pods                                                                       |
| container name / Docker DNS              | Service (ClusterIP) + CoreDNS               | same idea, different implementation                                                                 |
| frontend-net / backend-net / db-net      | NetworkPolicy (Sub-lab 3.6)                 | opposite default: Docker's custom bridges isolate by default, K8s Pods can reach any Pod by default |
| env_file: / plain env vars               | ConfigMap                                   | non-secret configuration — remember it does **not** auto-reload running Pods on change              |
| Docker secret / .env password            | Secret                                      | base64-encoded, not encrypted by default — same caveat as Lab 02 Step 9                             |
| named volume (pgdata)                    | PersistentVolumeClaim + PersistentVolume    | KinD backs this with local hostPath storage                                                         |
| HEALTHCHECK (Dockerfile)                 | livenessProbe / readinessProbe              | same idea, split into two distinct signals                                                          |
| mem_limit / cpus                         | resources.requests / resources.limits       | K8s distinguishes a soft "request" from a hard "limit"; Docker's flat limit doesn't                 |
| restart: unless-stopped                  | Pod restartPolicy                           | conceptually equivalent                                                                             |
| edge-proxy (nginx path routing)          | Ingress + ingress-nginx controller          | same job, cluster-native mechanism                                                                  |
| docker compose up --scale (punted on)    | replicas: on a Deployment                   | this is where K8s actually solves the problem Lab 02 Step 8 deferred                                |
| depends_on: condition: service_healthy   | initContainer (wait-for-dependency pattern) | Compose's gating has no Deployment equivalent; this is the idiomatic replacement                    |
| *(nothing — no one-off tasks in Lab 02)* | Job / CronJob                               | K8s-native way to run something once, or on a schedule, inside the cluster                          |

---

# Sub-lab 3.1 — KinD cluster fundamentals & core object literacy (toy examples only)

See the standalone Lab 3.1 document for full planned steps — this is the sub-lab currently in progress.

---

# Sub-lab 3.2 — ConfigMaps, Secrets, init containers, and the first real service (Postgres + one API)

**Purpose:** translate the smallest meaningful slice of the real app — Postgres + python-api only.

### Planned steps:

* `kind load docker-image` for `python-api:0.1.0`.
* ConfigMap for python-api's non-secret env vars; Secret for `DB_USER`/`DB_PASSWORD`.
* PersistentVolumeClaim for Postgres data.
* Postgres Deployment + Service (ClusterIP), referencing the ConfigMap/Secret, mounting the PVC.
* python-api Deployment + Service, with an **init container** that polls Postgres until it's reachable before the main container starts — the replacement for Compose's `depends_on: condition: service_healthy` — plus liveness/readiness probes against `/health`.
* Verify Pod-to-Pod DNS (`postgres-db` resolves from inside `python-api`'s Pod).
* Verify end-to-end via `kubectl port-forward`, confirm `db_status` connected and heartbeat count climbing.
* **Deliberate gotcha exercise:** edit the ConfigMap's value, confirm the running Pod's env var is unchanged (no auto-reload), then either manually roll a restart or add a checksum annotation to force one — see it happen once, on purpose.

---

# Sub-lab 3.3 — Completing the translation + Ingress (successor to edge-proxy)

**Purpose:** add node-api and react-frontend, then replace kubectl port-forward with a real Ingress.

### Planned steps:

* Repeat 3.2's pattern for node-api and react-frontend.
* Install ingress-nginx using KinD's specific install manifest.
* Write an Ingress mirroring Lab 02's `nginx.pathbased.conf` exactly, including the rewrite-target annotation for prefix stripping.
* Verify from the workstation — both status cards go green through one address.

---

# Sub-lab 3.4 — Replicas, load-balancing, and the round-robin payoff

**Purpose:** the direct payoff for the round-robin exercise deferred in Lab 02 Step 8.

### Planned steps:

* Scale node-api to 3 replicas — imperatively first, then declaratively.
* Verify the Service load-balances with zero extra config: poll `/api/node/api/info` through the Ingress, watch the `host` field rotate across Pod names, watch `kubectl get pods -o wide` show them spread across the 2 worker nodes.
* Watch `node_heartbeat` row counts climb faster with 3 concurrent writers.
* Trigger a rolling update; watch `kubectl rollout status` replace Pods one at a time with zero downtime.
* Deliberately break a readiness probe; observe the Pod stay Running but never Ready, correctly excluded from Service traffic.

---

# Sub-lab 3.5 — Batch & scheduled work: Job and CronJob

**Purpose:** give Jobs and CronJobs a real, non-contrived reason to exist in this app.

### Planned steps:

* Add a small cleanup script to the app (new tiny folder in the repo, e.g. `maintenance/cleanup.py` or `.js`) that deletes heartbeat rows older than N minutes from both tables, plus a minimal Dockerfile for it.
* Run it once as a plain **Job**, manually, to prove the script and DB connection work in-cluster.
* Convert it to a **CronJob** on a schedule (e.g. every 10 minutes), and discuss `concurrencyPolicy` (what happens if a run takes longer than the interval) and `restartPolicy: OnFailure/Never` (Jobs never use Always — worth understanding why).
* Verify: watch heartbeat row counts grow between runs, then drop back down right after a CronJob execution.

---

# Sub-lab 3.6 (stretch) — Hardening: NetworkPolicy, resource limits, StatefulSet, HPA

**Purpose:** close the gap between "it works" and "it works the way Lab 02's decisions insisted on" — and build the one object type (StatefulSet) that's genuinely core knowledge, not optional.

### Planned steps:

* NetworkPolicies recreating the three-network segmentation: deny-all-by-default, then explicit allows, confirming react-frontend cannot reach postgres-db.
* `resources.requests/resources.limits` on every Deployment; repeat Lab 02 Step 10's OOM experiment, K8s-native this time.
* **Convert Postgres from a Deployment to a StatefulSet**, using a `volumeClaimTemplate` instead of a shared PVC — built for real, including observing the stable Pod naming (`postgres-db-0`) that a Deployment never gives you.
* Optional: install metrics-server, add a small disposable load-generator Pod, and watch a HorizontalPodAutoscaler actually scale node-api in response to real load.
* Optional, lower priority: a minimal RBAC exercise — a debug Pod with a read-only ServiceAccount that can list Pods, since the app itself has no organic reason to call the K8s API.

---

# Verification checklist (whole lab)

* KinD cluster: 1 control-plane + 2 workers, all Ready.
* Toy objects from 3.1 fully cleaned up before 3.2 started.
* Init container correctly gates python-api/node-api startup on Postgres readiness.
* ConfigMap-edit-doesn't-auto-reload gotcha observed directly, then resolved via manual restart or checksum annotation.
* All five services running in `multi-service-app`; Ingress serves the full app from one address, both status cards green.
* node-api at 3 replicas: `/api/info`'s `host` field rotates; Pods visibly spread across both worker nodes.
* A rolling update completed with zero downtime.
* A deliberately broken readiness probe correctly excluded a Pod from Service traffic.
* Heartbeat cleanup Job runs successfully once, then on a CronJob schedule.
* (Stretch) NetworkPolicy confirmed blocking react-frontend → postgres-db.
* (Stretch) Postgres running as a StatefulSet with a stable Pod name and per-Pod PVC.
* (Stretch) HPA observed actually scaling node-api under generated load.
