# Lab 3.2 — ConfigMaps, Secrets, Init Containers & the First Real Service

## Objective
Translate the smallest meaningful slice of the real app — PostgreSQL + `python-api` only — onto the KinD cluster built in Sub-lab 3.1. Deliberately not touching `node-api` or `react-frontend` yet: with only two services, any mistake (a wrong selector, a probe pointed at the wrong path, a Secret key typo) has the fewest possible other moving parts to hide behind. This mirrors exactly how Lab 02 tested each API standalone against a throwaway Postgres before Compose tied everything together.

Unlike Sub-lab 3.1, **nothing built here gets deleted at the end** — this is the literal foundation Sub-lab 3.3 adds `node-api`, `react-frontend`, and the Ingress on top of.

## Environment
Same as Sub-lab 3.1 — the KinD cluster (1 control-plane + 2 workers) must already exist; this sub-lab doesn't create a new one, it populates the `multi-service-app` namespace inside the existing cluster.

| Role | Hostname | IP | Software |
|---|---|---|---|
| KinD host | `ubuntuserver1.ssa.veeam.local` | 172.31.17.182 | `kubectl`, `kind`, existing 3-node cluster |
| Control point | Windows workstation | 172.24.209.0/24 | Browser + SSH client |

## Decisions locked in for this sub-lab

- **Postgres stays a plain Deployment with one PVC for now.** A StatefulSet is the more "correct" object for Postgres, but that upgrade — and the reasoning for it — is deliberately saved for Sub-lab 3.6, once a Deployment-based version already works and can be compared against.
- **One shared Secret, consumed under different names by different consumers.** Postgres and `python-api` need the *same* username/password values but expect them under *different* env var names (`POSTGRES_USER`/`POSTGRES_PASSWORD` vs. `DB_USER`/`DB_PASSWORD`). Rather than duplicating the values into two Secrets, one Secret (`db-credentials`) holds the raw values under generic keys (`username`, `password`), and each Deployment maps that key to whatever env var name it actually needs via `valueFrom.secretKeyRef`. This is worth noticing as a genuine capability Compose's `env_file:` doesn't have — Compose sets the env var name exactly as written in the file; Kubernetes lets you rename at the point of consumption.
- **Two ConfigMaps, not one.** `postgres-config` and `python-api-config`, kept separate and owned by their respective Deployment — mirroring Lab 02's per-service `.env` files rather than one giant shared blob.
- **Init container reuses the `postgres:16-alpine` image**, running `pg_isready` in a loop, rather than building a new image just for a dependency check. This is the replacement for Compose's `depends_on: condition: service_healthy`.
- **No resource requests/limits yet** — deferred to Sub-lab 3.6, consistent with adding one new concept at a time.

## Planned Steps

### Step 1 — Load the `python-api` image into the cluster
`kind load docker-image` the `python-api:0.1.0` image built back in Lab 02 Step 4 into the KinD cluster's nodes. Worth pausing on *why* this step exists at all: a real cluster (including EKS later) pulls images from a registry every node can reach; KinD has no registry by default, so this command is a local shortcut that copies the image directly into each node's containerd store. Flag this explicitly as something that goes away once the GitHub Actions/registry lab exists.

### Step 2 — Create the shared `db-credentials` Secret
One Secret, two generic keys (`username`, `password`), holding the same real credentials chosen back in Lab 02. This is the object every other step in this sub-lab depends on, so it comes first.

### Step 3 — Create `postgres-config`
A ConfigMap holding Postgres's own non-secret setting — its database name (`POSTGRES_DB`). Small on purpose; there isn't much non-secret Postgres configuration in this app.

### Step 4 — Create `python-api-config`
A ConfigMap holding `python-api`'s non-secret env vars: `DB_HOST` (the Service name from Step 7, decided in advance), `DB_PORT`, `DB_NAME`, `DB_SSLMODE`, `DB_CONNECT_TIMEOUT` — a direct translation of Lab 02's `api-python/.env`, minus the password.

### Step 5 — Create the PersistentVolumeClaim for Postgres data
A PVC requesting storage for `/var/lib/postgresql/data` — the direct translation of the `pgdata` named volume from Lab 02. On KinD this binds to a local hostPath-backed PersistentVolume automatically; worth noting explicitly that this auto-provisioning behavior is a KinD default, not something every cluster does out of the box.

### Step 6 — Write and apply the Postgres Deployment
A single-replica Deployment referencing `postgres-config` (via `envFrom`) and `db-credentials` (via `env`/`valueFrom`, mapped to `POSTGRES_USER`/`POSTGRES_PASSWORD`), mounting the PVC at the correct path. Add a `readinessProbe` and `livenessProbe` using an `exec` probe running `pg_isready` — the Kubernetes-native equivalent of the `--health-cmd` flag used all the way back in Lab 02 Step 6's standalone `docker run`.

### Step 7 — Write and apply the Postgres Service
A ClusterIP Service named `postgres-db`, selecting the Deployment's Pods by label. The name matters — it's what `DB_HOST` in `python-api-config` (Step 4) points at, and what DNS resolution in Step 11 will prove works.

### Step 8 — Confirm Postgres is actually healthy before moving on
Check the Deployment's rollout status and the Pod's readiness before building anything that depends on it — same "isolate one variable" discipline as every prior lab. Don't proceed to Step 9 until this is genuinely green, not just "probably fine."

### Step 9 — Write the `python-api` Deployment, with an init container
This is the step with the most new material. The Deployment needs:
- An **init container** using the `postgres:16-alpine` image, running a loop of `pg_isready -h postgres-db -p 5432` until it succeeds — the main container never even starts until this exits successfully. This is the direct, idiomatic replacement for Compose's `depends_on: condition: service_healthy`, which has no equivalent field on a Kubernetes Deployment.
- The main `python-api` container, wired to `python-api-config` (`envFrom`) and `db-credentials` (`env`/`valueFrom`, mapped this time to `DB_USER`/`DB_PASSWORD` — same Secret as Postgres, different env var names, per the "Decisions locked in" note above).
- `readinessProbe`/`livenessProbe` as `httpGet` checks against the existing `/health` endpoint — the same endpoint Lab 02's Dockerfile `HEALTHCHECK` already used.

### Step 10 — Write and apply the `python-api` Service
A ClusterIP Service named `python-api`, selecting the Deployment's Pods.

### Step 11 — Verify Pod-to-Pod DNS
Exec into the `python-api` Pod and resolve `postgres-db` by name. This is the direct Kubernetes analog of Lab 02 Step 7's `db-net` DNS check — same underlying idea (a service reachable by name because it's meant to be), different mechanism (CoreDNS instead of Docker's embedded resolver).

### Step 12 — Verify end-to-end
`kubectl port-forward` to the `python-api` Service, then hit `/health` and `/api/db` from the Ubuntu host. `/api/db` should show `db_status` connected, with the heartbeat count climbing — the same proof used at every prior stage of this project, now running on Kubernetes.

### Step 13 — The ConfigMap gotcha, on purpose
Edit `python-api-config` — change `DB_CONNECT_TIMEOUT` to a different value — and re-apply it. Exec into the running Pod and print its environment: the old value is still there. This is deliberate, not a bug to chase — Kubernetes does not watch ConfigMaps for changes and restart Pods automatically. Force the update the straightforward way: a manual rollout restart of the Deployment. Confirm the new Pod picks up the updated value. (Worth knowing, not necessarily doing today: production setups often automate this with a checksum annotation on the Pod template that changes whenever the ConfigMap does, forcing a rollout automatically — a good thing to research once this manual version makes sense.)

## Verification checklist
- [ ] `python-api:0.1.0` present in the KinD cluster's nodes (`kind load docker-image` completed without error).
- [ ] `db-credentials` Secret, `postgres-config` and `python-api-config` ConfigMaps, and the Postgres PVC all created in `multi-service-app`.
- [ ] Postgres Deployment reports `Ready`, readiness/liveness probes passing.
- [ ] `python-api` Pod's init container completed successfully before the main container started — visible in `kubectl describe pod`.
- [ ] `python-api` Pod resolves `postgres-db` by name from inside the Pod.
- [ ] `/api/db` (via port-forward) shows `db_status` connected and heartbeat count climbing.
- [ ] Editing `python-api-config` did **not** change the running Pod's environment until a manual rollout restart was performed — gotcha observed directly, not just read about.
