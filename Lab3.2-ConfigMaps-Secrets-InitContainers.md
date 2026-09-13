# Lab 3.2 — ConfigMaps, Secrets, Init Containers & the First Real Service

Detailed walkthrough — builds on the `lab3` KinD cluster from Sub-lab 3.1.

## How to Use This Guide

Same format as 3.1: **Run → Expect → Why it matters.** Sections marked **[Deep dive]** are additions to the brief.

New in this sub-lab: **⚠️ Gotcha boxes.** Lab 3.2 has five failure modes that produce confusing symptoms, and each one costs an hour if you meet it cold. They're marked where they'd bite.

Nothing here gets deleted at the end. Sub-lab 3.3 builds directly on top of it.

## Glossary

**Probe:** in Kubernetes, a probe is a health check. It is Kubernetes asking the container: "Are you okay?", "Are you ready to receive traffic?", "Did you start correctly?"

- health probe = *comprobación de salud*
- readiness probe = *comprobación de disponibilidad* → can this container receive traffic now?
- liveness probe = *comprobación de vida / comprobación de funcionamiento* → is this container broken and should it be restarted?
- startup probe = *comprobación de arranque*

**Init container:** a special container that runs before the main application container(s) start.

---

## ⚠️ Before Anything: Two Discrepancies to Resolve

**1. The IP changed.** Sub-lab 3.1 listed the host as `172.31.17.54`. This brief says `172.31.17.182`. Check which is real before you rely on it:

```bash
hostname -I
ip -4 addr show | grep inet
```

If it genuinely changed (DHCP lease), nothing in the cluster breaks — KinD binds the API server to `127.0.0.1` and you access everything over SSH. Only your SSH target changes.

**2. Values you need from Lab 02.** This guide can't know them. Fill this in now and substitute throughout:

| Thing | Where to find it | Your value |
|---|---|---|
| DB name | Lab 02 `POSTGRES_DB` | ______ (guide uses `appdb`) |
| DB user | Lab 02 `POSTGRES_USER` | ______ (guide uses `appuser`) |
| DB password | Lab 02 `POSTGRES_PASSWORD` | ______ |
| python-api listen port | see Step 0.4 | ______ (guide uses `8000`) |
| Health endpoint path | Lab 02 Dockerfile `HEALTHCHECK` | ______ (guide uses `/health`) |

---

## Step 0 — Pre-Flight

### 0.1 — Confirm the Cluster From 3.1 Is Intact

```bash
kubectl config current-context          # kind-lab3
kubectl get nodes                        # 3 nodes, all Ready
kubectl get pods -A | head
```

If the context is wrong or missing:

```bash
kind get clusters
kubectl config use-context kind-lab3
```

If the cluster is gone entirely, rebuild from the config file — not with a bare `kind create cluster`, or you lose the `extraPortMappings`:

```bash
kind create cluster --config ~/lab3/kind-lab3.yaml
```

### 0.2 — Confirm the Namespace and Your Context Default

```bash
kubectl get ns multi-service-app
kubectl config view --minify | grep namespace:
```

**Expect:** the namespace exists, and your context default is `multi-service-app`. If not:

```bash
kubectl create namespace multi-service-app
kubectl config set-context --current --namespace=multi-service-app
```

From here on, commands omit `-n multi-service-app`. If you ever see "not found" for something you know you created, check this first.

### 0.3 — Confirm 3.1's Toys Are Gone

```bash
kubectl get all -n default
```

**Expect:** only `service/kubernetes`. If Step 7 of 3.1 was skipped, clean up now — leftover Pods in `default` will muddy every `kubectl get pods -A` you run today.

### 0.4 — Find Your App's Actual Port and Endpoints

Don't guess these. The image knows:

```bash
docker images | grep python-api     # python-api:0.1.0
docker image inspect python-api:0.1.0 --format '{{json .Config.ExposedPorts}}'
# {"8001/tcp":{}}
docker image inspect python-api:0.1.0 --format '{{json .Config.Cmd}} {{json .Config.Entrypoint}}'
# ["python","main.py"] null
docker image inspect python-api:0.1.0 --format '{{json .Config.Healthcheck}}'
```

```
{"Test":["CMD-SHELL","python -c \"import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://localhost:8001/health').status==200 else sys.exit(1)\""],"Interval":10000000000,"Timeout":3000000000,"StartPeriod":5000000000,"Retries":3}
```

```bash
docker image inspect python-api:0.1.0 --format '{{json .Config.Env}}'
```

```
["PATH=/opt/venv/bin:/usr/local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin","LANG=C.UTF-8","GPG_KEY=7169605F62C751356D054A26A821E680E5FA6305","PYTHON_VERSION=3.12.14","PYTHON_SHA256=5c8462af5790baf43a321a1559dbe0db06d1be4300fb85fb53c40060668e548a"]
```

Cross-check against Lab 02's Compose file and env file:

```bash
grep -A15 'python' ~/multi-service-App/docker-compose.yml
# -A15 means show 15 lines after the matching line
```

This is the python section of the compose file:

```yaml
python-api:
  build:
    context: ./api-python
  image: python-api:0.1.0
  container_name: python-api
  env_file:
    - api-python/.env
  networks:
    - backend-net
    - db-net
  depends_on:
    postgres-db:
      condition: service_healthy
  mem_limit: 256m
  cpus: 0.5
  restart: unless-stopped
```

```bash
cat ~/multi-service-App/api-python/.env
```

```
DB_HOST=postgres-db
DB_PORT=5432
DB_NAME=testdb
DB_USER=testuser
DB_PASSWORD=a-real-password-you-pick
DB_SSLMODE=disable
DB_CONNECT_TIMEOUT=3
```

**Why it matters:** the single most common failure in this sub-lab is a probe pointed at the wrong port. `httpGet` against a closed port produces `Readiness probe failed: connection refused`, the Pod never goes Ready, the Service has no endpoints, and you spend twenty minutes debugging the Service. Two minutes here prevents it.

Common defaults: Flask → 5000, FastAPI/uvicorn → 8000, gunicorn → 8000. This guide uses `8000` — change it if yours differs.

### 0.5 — Make a Working Directory

```bash
mkdir -p ~/lab3/msa
cd ~/lab3/msa
```

Separate from `~/lab3/manifests/` (which holds 3.1's throwaways). Files are numbered so `kubectl apply -f .` processes them in a sane order — `kubectl apply` on a directory is alphabetical, not dependency-aware.

---

## Step 1 — Load the python-api Image Into the Cluster

### 1.1 — Confirm the Image Exists on the Host

```bash
docker images python-api
```

**Expect:** `python-api  0.1.0  <id>  <size>`. If it's missing, rebuild it from Lab 02 before continuing:

```bash
cd ~/multi-service-App/api-python && docker build -t python-api:0.1.0 .
cd ~/lab3/msa
```

### 1.2 — Load It

```bash
kind load docker-image python-api:0.1.0 --name lab3
```

When using kind, your Kubernetes cluster runs inside Docker containers. Even if an image exists on your host machine, the kind cluster may not be able to use it directly. `kind load docker-image` exports that local image and imports it into the container runtime inside each kind node.

**Expect:** a short progress output, then silence. Takes 10–60s depending on image size.

### 1.3 — Verify It Landed on Every Node

```bash
for n in lab3-control-plane lab3-worker lab3-worker2; do
  echo "== $n"
  docker exec "$n" crictl images | grep python-api || echo "   MISSING"
done
```

**Expect:** present on all three. `kind load` copies to every node, which is why it's slow.

**Why this step exists at all:** a real cluster pulls images from a registry — Docker Hub, ECR, GHCR — that every node can reach. KinD ships no registry. So `kind load` is a shortcut that streams the image straight into each node's containerd store, bypassing registries entirely.

Note the two separate image stores on this host:

```bash
docker images | grep python-api                          # host Docker's store
docker exec lab3-worker crictl images | grep python-api   # the node's containerd store
```

Same image, two copies, no connection between them. Building an image on the host does not make it visible to the cluster. That surprise is coming in 3.3 when you build `node-api` and `react-frontend`.

### ⚠️ Gotcha 1 — the `:latest` Trap

Kubernetes' default `imagePullPolicy` depends on the tag:

| Tag | Default policy | Result on KinD |
|---|---|---|
| `python-api:0.1.0` | `IfNotPresent` | Uses the loaded image ✅ |
| `python-api:latest` | `Always` | Tries to pull from Docker Hub → `ErrImagePull` ❌ |

You're using `0.1.0`, so you're fine. But set it explicitly anyway — it documents intent and survives someone retagging later:

```yaml
imagePullPolicy: IfNotPresent
```

Every manifest below includes it.

### ⚠️ Gotcha 2 — Reloading After a Rebuild

When you change the code and rebuild with the same tag, then `kind load` again, the running Pod does not pick it up. Kubernetes sees the same image name and has no reason to act.

```bash
docker build -t python-api:0.1.0 .
kind load docker-image python-api:0.1.0 --name lab3
kubectl rollout restart deployment/python-api      # <- required
```

Better habit: bump the tag (`0.1.1`) and `kubectl set image`. Then the change is visible in `kubectl describe` and rollout history instead of being invisible state.

### 1.4 — [Deep Dive] Also Preload the Postgres Image

Postgres will be pulled from Docker Hub by default. Preloading avoids a network dependency mid-lab and makes Step 6 start instantly:

```bash
docker pull postgres:16-alpine
kind load docker-image postgres:16-alpine --name lab3
```

**Here I got this error:**

```
ERROR: failed to load image: command "docker exec --privileged -i lab3-worker2 ctr --namespace=k8s.io images import --all-platforms --digests --snapshotter=overlayfs -" failed with error: exit status 1
Command Output: ctr: content digest sha256:b8825b49a67f7e332f48cd92ce1891afd5736188c29d713e472e44d5b7549f00: not found
```

The issue was likely related to how `kind load docker-image` imports image content into the node container runtime. The PostgreSQL image is a public/multi-platform image, and the import failed because containerd expected an internal content digest that was not present during the import.

Instead of using `kind load`, the image was pulled directly inside each kind node with `crictl`:

```bash
for n in lab3-control-plane lab3-worker lab3-worker2; do
  echo "== Pulling postgres on $n"
  docker exec "$n" crictl pull docker.io/library/postgres:16-alpine
done
```

To confirm if it was loaded:

```bash
for n in lab3-control-plane lab3-worker lab3-worker2; do
  echo "== $n"
  docker exec "$n" crictl images | grep postgres || echo "   MISSING"
done
```

You'll use this same image twice — once for the database, once for the init container's `pg_isready`.

### 1.5 — [Deep Dive] What Replaces This Later

The registry-less shortcut disappears the moment you have CI (continuous integration). In other words, right now we are pulling images inside nodes manually. That works for a local lab, but in real environments you normally do not manually load images into nodes.

Instead, the normal flow is: developer pushes code → CI builds Docker image → CI pushes image to registry → Kubernetes pulls image from registry.

Two ways forward:

- **Local registry** — run a `registry:2` container on the Docker network, configure containerd on each node to trust it. KinD documents a script for this. Push once, all nodes pull.
- **Real registry** — GHCR or ECR, with an `imagePullSecret` in the namespace.

Worth knowing the shape of the second, since it's what EKS will need:

```bash
# Not for today — just so you recognise it later
kubectl create secret docker-registry ghcr-creds \
  --docker-server=ghcr.io --docker-username=USER --docker-password=TOKEN
```

---

## Step 2 — Create the Shared db-credentials Secret

### ⚠️ Gotcha 3 — Don't Put the Password in Your Shell History

`--from-literal=password=hunter2` writes the password to `~/.bash_history` in plaintext. The recommended way: read it into a variable interactively.

```bash
read -rs -p "DB password: " DB_PASS; echo
```

Reads user input from the terminal: `-r` raw, `-s` silent (what you type is not displayed on screen), `-p` shows this prompt before reading input.

```bash
kubectl create secret generic db-credentials \
  --from-literal=username=appuser \
  --from-literal=password="$DB_PASS"

unset DB_PASS
```

### 2.1 — Verify

```bash
kubectl get secret db-credentials
kubectl describe secret db-credentials
```

**Expect:** `Type: Opaque`, `Data: 2`, with `username` and `password` shown as byte counts — `describe` never prints values.

### 2.2 — Prove Base64 Is Not Encryption

```bash
kubectl get secret db-credentials -o jsonpath='{.data.password}' | base64 -d; echo
```

Your password, in plaintext, from a one-liner.

**Why it matters — the single most misunderstood thing in Kubernetes:**

> A Secret is not encrypted. It is base64-encoded, which is an encoding, not a cipher. Anyone who can read the Secret can read the value.

What a Secret actually gives you over a ConfigMap:

- Values don't appear in `kubectl describe` or most log output
- Not written to the node's disk in plaintext — mounted as tmpfs (RAM)
- A separate RBAC resource type, so you can grant ConfigMap access without Secret access
- Can be encrypted at rest in etcd — but only if the cluster is configured for it, and KinD is not by default

Confirm that last point:

```bash
docker exec lab3-control-plane grep -c encryption-provider-config \
  /etc/kubernetes/manifests/kube-apiserver.yaml
```

`0` means Secrets are sitting in etcd in plaintext right now.

The practical rule: Secrets keep credentials out of your ConfigMaps, manifests, and git. They do not protect against someone with cluster access. Real protection needs encryption-at-rest plus RBAC, or an external system — Sealed Secrets, External Secrets Operator, Vault.

### 2.3 — [Deep Dive] The stringData Field

Writing a Secret manifest by hand, you'd have to base64 everything. `stringData` does it for you:

```yaml
apiVersion: v1
kind: Secret
metadata:
  name: db-credentials
type: Opaque
stringData:              # plaintext in, base64 out
  username: appuser
  password: YOUR_PASSWORD
```

Useful, but note what it means: that file must never reach git. Which is exactly why Step 2 uses imperative creation and no file at all.

If you want a file for reference without the values:

```bash
kubectl get secret db-credentials -o yaml > ~/lab3/.secrets/db-credentials.yaml
chmod 600 ~/lab3/.secrets/db-credentials.yaml
```

Add `.secrets/` to `.gitignore` before you forget.

### 2.4 — [Deep Dive] Why One Secret, Not Two

Postgres wants `POSTGRES_USER`. python-api wants `DB_USER`. Same value, different names.

Compose can't solve this cleanly — `env_file:` sets the variable name exactly as written, so you'd duplicate the credentials into two files and hope they stay in sync. Kubernetes decouples storage from naming:

```
db-credentials
  ├── username ──▶ POSTGRES_USER  (postgres Deployment)
  └── username ──▶ DB_USER        (python-api Deployment)
```

One source of truth, renamed at the point of consumption via `secretKeyRef`. Rotating the password means editing one object. You'll write both mappings in Steps 6 and 9 — notice they reference the identical key: `username`.

---

## Step 3 — Create postgres-config

```bash
cat > ~/lab3/msa/02-postgres-config.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: postgres-config
  labels:
    app: postgres
data:
  POSTGRES_DB: "appdb"
EOF

kubectl apply -f ~/lab3/msa/02-postgres-config.yaml
kubectl get configmap postgres-config -o yaml
```

Substitute your real DB name for `appdb`.

**Why it's this small:** almost all Postgres tuning lives in `postgresql.conf`, not env vars. The official image only reads a handful at first boot: `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_INITDB_ARGS`, `PGDATA`. Two of those are secret, so one lands here.

**⚠️ Note the quotes.** ConfigMap data values must be strings. `POSTGRES_DB: appdb` works, but `POSTGRES_PORT: 5432` fails — YAML parses it as an integer and the API rejects it. Quote everything numeric:

```yaml
data:
  SOME_PORT: "5432"       # correct
  # SOME_PORT: 5432       # rejected: cannot unmarshal number into string
```

This bites in Step 4, which has several numeric values.

---

## Step 4 — Create python-api-config

```bash
cat > ~/lab3/msa/03-python-api-config.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: python-api-config
  labels:
    app: python-api
data:
  DB_HOST: "postgres-db"
  DB_PORT: "5432"
  DB_NAME: "appdb"
  DB_SSLMODE: "disable"
  DB_CONNECT_TIMEOUT: "5"
EOF

kubectl apply -f ~/lab3/msa/03-python-api-config.yaml
kubectl get cm python-api-config -o jsonpath='{.data}' | python3 -m json.tool
```

Field notes:

- `DB_HOST: "postgres-db"` — this is a DNS name that does not exist yet. It'll resolve once Step 7 creates the Service. Writing config that points at a not-yet-created name feels wrong coming from Compose, and it's correct here: Kubernetes objects are declarations, and DNS resolves at request time, not at apply time.
- `DB_SSLMODE: "disable"` — fine inside a cluster on a lab network. In production, in-cluster traffic is often still unencrypted and mTLS is handled by a service mesh, but that's a much later conversation.
- `DB_CONNECT_TIMEOUT: "5"` — the value you'll change in Step 13. Note the quotes.

### ⚠️ Gotcha 4 — DB_NAME and POSTGRES_DB Must Match

They're in two different ConfigMaps and nothing validates them against each other. If `postgres-config` creates `appdb` and `python-api-config` connects to `appdb_prod`, Postgres starts fine, the init container's `pg_isready` succeeds, and python-api fails with `FATAL: database "appdb_prod" does not exist`.

Check them side by side before moving on:

```bash
echo "postgres  POSTGRES_DB: $(kubectl get cm postgres-config    -o jsonpath='{.data.POSTGRES_DB}')"
echo "python    DB_NAME    : $(kubectl get cm python-api-config -o jsonpath='{.data.DB_NAME}')"
```

Why duplication is tolerated here: each Deployment owns its own config, mirroring Lab 02's per-service `.env` files. The alternative — one shared ConfigMap — creates coupling where a change for one service silently affects another. Duplication with a verification step is the lesser evil at this scale. At larger scale you'd use Kustomize or Helm to template both from one source.

### 4.1 — [Deep Dive] ConfigMap Consumption Modes

Three ways to get a ConfigMap into a container, with meaningfully different behaviour:

| Mode | Syntax | Live update? |
|---|---|---|
| All keys → env vars | `envFrom.configMapRef` | Never |
| One key → one env var | `env.valueFrom.configMapKeyRef` | Never |
| Keys → files in a volume | `volumes.configMap` | Yes, ~60s |

**Option 1:** load all keys from the ConfigMap as environment variables inside the container. If you update the ConfigMap later, the running container does not get the new values automatically.

**Option 2:** load one specific key from a ConfigMap as one environment variable. Same issue — environment variables are created when the process starts. If the ConfigMap changes, the running process does not get updated.

Pod restart is required for both.

**Option 3:** mount the ConfigMap as files inside the container. Inside the container, Kubernetes creates files like:

```
/etc/app-config/DB_HOST
/etc/app-config/DB_PORT
/etc/app-config/DB_NAME
```

Environment variables are set once at process start — that's a Linux fact, not a Kubernetes limitation. A running process cannot have its environment changed from outside. Mounted files can be swapped underneath a running container, so volume-mounted config does update, though your app has to notice and re-read the file.

You're using `envFrom`, which is why Step 13's gotcha exists. Step 13.4 has a demonstration of the volume-mount contrast.

---

## Step 5 — Create the PersistentVolumeClaim

Step 5 creates storage for PostgreSQL. Postgres is a database, so it needs a place to store data permanently — without persistent storage, the data can disappear when the Pod is deleted or recreated.

```bash
cat > ~/lab3/msa/04-postgres-pvc.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: postgres-pvc
  labels:
    app: postgres
spec:
  accessModes:
    - ReadWriteOnce       # the volume can be mounted as read-write by Pods running on one node
  resources:
    requests:
      storage: 2Gi
  storageClassName: standard    # in kind, "standard" usually maps to local-path storage
EOF

kubectl apply -f ~/lab3/msa/04-postgres-pvc.yaml
kubectl get pvc
```

### ⚠️ Gotcha 5 — the PVC Will Say Pending, and That's Correct

```
NAME           STATUS    VOLUME   CAPACITY   STORAGECLASS   AGE
postgres-pvc   Pending                                       standard       5s
```

Do not debug this. Check why:

```bash
kubectl describe pvc postgres-pvc | tail -5
kubectl get storageclass
```

**Expect:** the event says `waiting for first consumer to be created before binding`, and the StorageClass shows `VOLUMEBINDINGMODE: WaitForFirstConsumer`.

Why: KinD's local-path provisioner creates storage on a specific node's disk. It can't choose the node until it knows where the Pod will be scheduled. So it waits. The PVC binds the moment Step 6's Pod is scheduled, and not before.

This directly contradicts the verification checklist's "PVC created" — it's created, just not `Bound`. That's the correct state at this point in the lab.

Field notes:

- `accessModes: ReadWriteOnce` — mountable read-write by Pods on one node. Not "one Pod". This constrains Step 6's update strategy; see 6.3.
- `storageClassName: standard` — KinD's default. Verify with `kubectl get sc`; the one marked `(default)` is what you'd get by omitting the field.
- `storage: 2Gi` — local-path does not actually enforce this. It creates a directory on the node's filesystem, and your Postgres can grow past 2Gi without complaint. A cloud provisioner carving an EBS volume would enforce it strictly. Don't build a mental model of storage requests from KinD's behaviour.

### 5.1 — [Deep Dive] The PV/PVC/StorageClass Triangle

```
StorageClass  ("how to make storage")
  ← cluster-scoped, admin-owned
      │  provisions on demand
      ▼
PersistentVolume  ("this specific chunk of storage")
  ← cluster-scoped
      │  bound 1:1
      ▼
PersistentVolumeClaim  ("I need storage like this")
  ← namespaced, app-owned
      │  referenced by
      ▼
Pod volume mount
```

The PVC is the app's request; the PV is the fulfilment. Dynamic provisioning means the PV doesn't exist until a PVC asks for one. Before that was standard, an admin pre-created PVs by hand and PVCs matched against the pool.

After Step 6, look at what got made:

```bash
kubectl get pv
kubectl get pv -o custom-columns=\
NAME:.metadata.name,CLAIM:.spec.claimRef.name,PATH:.spec.hostPath.path,POLICY:.spec.persistentVolumeReclaimPolicy
```

Then find the actual directory on the node:

```bash
NODE=$(kubectl get pod -l app=postgres -o jsonpath='{.items[0].spec.nodeName}')
docker exec "$NODE" ls -la /var/local-path-provisioner/
```

That's your database, sitting in a directory inside a Docker container. Which reveals the honest limitation: this data is pinned to one node. If that node dies, the data goes with it. A Pod rescheduled elsewhere can't reach it. That's not a KinD quirk — it's what `hostPath`-class storage means, and it's the gap that networked storage (EBS, NFS, Ceph) fills in a real cluster.

Note also `persistentVolumeReclaimPolicy: Delete` — deleting the PVC deletes the PV and your data. Worth knowing before a careless cleanup.

When updating the Postgres Deployment, Kubernetes must avoid creating a second Postgres Pod that tries to use the same PVC at the same time. That can cause problems. For a database using `ReadWriteOnce` storage, you often want an update strategy that stops the old Pod before starting the new one. That strategy is usually:

```yaml
strategy:
  type: Recreate
```

---

## Step 6 — Write and Apply the Postgres Deployment

### 6.1 — The Manifest

```bash
cat > ~/lab3/msa/05-postgres-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: postgres
  labels:
    app: postgres
spec:
  replicas: 1
  strategy:
    type: Recreate          # see 6.3 — required with a ReadWriteOnce PVC
  selector:
    matchLabels:
      app: postgres
  template:
    metadata:
      labels:
        app: postgres
    spec:
      containers:
        - name: postgres
          image: postgres:16-alpine
          imagePullPolicy: IfNotPresent
          ports:
            - name: postgres
              containerPort: 5432

          # Non-secret config: every key in the ConfigMap becomes an env var
          envFrom:
            - configMapRef:
                name: postgres-config

          # Secret values, renamed at the point of consumption
          env:
            - name: POSTGRES_USER
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: username
            - name: POSTGRES_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
            # See 6.2 — keeps the data dir one level below the mount point
            - name: PGDATA
              value: /var/lib/postgresql/data/pgdata

          volumeMounts:
            - name: postgres-data
              mountPath: /var/lib/postgresql/data

          readinessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -h 127.0.0.1"]
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3

          livenessProbe:
            exec:
              command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -d \"$POSTGRES_DB\" -h 127.0.0.1"]
            initialDelaySeconds: 30
            periodSeconds: 10
            timeoutSeconds: 5
            failureThreshold: 6

      volumes:
        - name: postgres-data
          persistentVolumeClaim:
            claimName: postgres-pvc
EOF

kubectl apply -f ~/lab3/msa/05-postgres-deployment.yaml
```

### 6.2 — Why PGDATA Points One Level Deeper

In the Deployment you have:

```yaml
- name: PGDATA
  value: /var/lib/postgresql/data/pgdata   # Postgres will store the actual database files here
```

And the PVC is mounted here:

```yaml
volumeMounts:
  - name: postgres-data
    mountPath: /var/lib/postgresql/data    # the volume is mounted here
```

This is a real trap with the official Postgres image, and it's worth understanding rather than just copying.

`initdb` refuses to run in a directory that isn't empty. When a PV is mounted at `/var/lib/postgresql/data`, the directory may already contain filesystem artifacts — classically `lost+found` on ext4. Postgres sees a non-empty directory, refuses to initialise, and the Pod enters `CrashLoopBackOff` with a message about the directory containing files.

Setting `PGDATA=/var/lib/postgresql/data/pgdata` puts the database in a subdirectory of the mount point, which Postgres creates itself and therefore controls completely.

KinD's local-path provisioner uses a plain directory with no `lost+found`, so you might get away without it. On EKS with an EBS-backed PV you would not. The alternative fix is `subPath: postgres` on the volumeMount — same idea, different mechanism.

Set it now so the manifest is portable.

### 6.3 — Why strategy: Recreate

`RollingUpdate` behavior: start new Pod → wait for new Pod to be Ready → stop old Pod.

The default is `RollingUpdate`: start the new Pod, wait for it to be Ready, then terminate the old one. Briefly, two Pods exist.

With a `ReadWriteOnce` PVC, the new Pod can't mount the volume while the old one holds it — if they land on different nodes, it can't mount at all. The new Pod hangs in `ContainerCreating` with `Multi-Attach error` or `volume is already exclusively attached`, waiting for a Pod that's waiting for it. Deadlock until you intervene.

`Recreate` inverts the order: terminate the old Pod completely, then start the new one. You get downtime — correct for a single-replica database, which has no way to avoid downtime anyway.

The general rule: stateful single-replica workloads with RWO storage use `Recreate`. Stateless workloads use `RollingUpdate`. python-api in Step 9 keeps the default.

### 6.4 — Why the Probes Look Like That

Both run `pg_isready`, but they answer different questions and the consequences differ enormously:

| | readinessProbe | livenessProbe |
|---|---|---|
| Asks | "Can I take traffic?" | "Am I broken beyond recovery?" |
| On failure | Pod removed from Service endpoints | Container killed and restarted |
| Recovers when | Probe passes again | After restart |

Note the timing difference: readiness starts at 5s and fails fast; liveness waits 30s and tolerates 6 failures. That asymmetry is deliberate.

**⚠️ A too-aggressive liveness probe is worse than none at all.** If liveness fires during a slow startup — Postgres replaying WAL after an unclean shutdown, say — it kills the container mid-recovery, which starts recovery over, which takes longer, which fires liveness again. A permanent crash loop caused entirely by the health check. Generous `initialDelaySeconds` and `failureThreshold` on liveness; tight values on readiness.

`-h 127.0.0.1` forces a TCP connection rather than a Unix socket, so the probe tests the same path clients use. Without it, `pg_isready` can report success while the network listener isn't up.

**[Deep dive]** The modern answer to slow starts is a `startupProbe`, which suspends liveness until the app has come up once:

```yaml
startupProbe:
  exec:
    command: ["sh", "-c", "pg_isready -U \"$POSTGRES_USER\" -h 127.0.0.1"]
  periodSeconds: 5
  failureThreshold: 30        # up to 150s to start
```

With that present, `livenessProbe.initialDelaySeconds` becomes unnecessary. Cleaner than guessing a delay.

### 6.5 — Watch It Come Up

```bash
kubectl get pods -w
```

In a second session:

```bash
kubectl get pvc                     # Pending → Bound, right about now
kubectl get pv                      # This shows the actual storage object; the PV is bound to your PVC
kubectl rollout status deployment/postgres --timeout=180s   # checks whether the Postgres rollout completed
kubectl logs -l app=postgres --tail=40
```

**Expect in the logs:** `database system is ready to accept connections`.

Note the transition in `kubectl get pods`: READY goes `0/1` → `1/1` a few seconds after STATUS: `Running`. `Running` means the container process started. `1/1` means the readiness probe passed. Those are different things, and the gap between them is exactly what readiness probes exist to represent.

### 6.6 — Verify From Inside

Instead of only asking Kubernetes if things are okay, you enter/execute commands inside the Postgres Pod.

```bash
POD=$(kubectl get pod -l app=postgres -o jsonpath='{.items[0].metadata.name}')

kubectl exec "$POD" -- env | grep -E 'POSTGRES_|PGDATA' | sort
kubectl exec "$POD" -- pg_isready -U appuser -d appdb -h 127.0.0.1
kubectl exec -it "$POD" -- psql -U appuser -d appdb -c '\l'
kubectl exec "$POD" -- ls -la /var/lib/postgresql/data/
```

**Expect:** the env shows `POSTGRES_DB` (from the ConfigMap) alongside `POSTGRES_USER`/`POSTGRES_PASSWORD` (from the Secret), with no indication of which came from where. That's the point — the container just sees environment variables. The distinction between ConfigMap and Secret exists entirely on the Kubernetes side.

Also note the password is visible in `kubectl exec ... env`. Another reminder about what Secrets do and don't protect.

The last command should show your `pgdata` subdirectory from 6.2, confirming that fix took effect.

---

## Step 7 — Postgres Service

```bash
cat > ~/lab3/msa/06-postgres-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: postgres-db
  labels:
    app: postgres
spec:
  type: ClusterIP
  selector:
    app: postgres
  ports:
    - name: postgres
      port: 5432
      targetPort: 5432
      protocol: TCP
EOF

kubectl apply -f ~/lab3/msa/06-postgres-service.yaml

kubectl get svc postgres-db
kubectl get endpointslices -l kubernetes.io/service-name=postgres-db
```

**Expect:** a ClusterIP in `10.96.0.0/16`, and an EndpointSlice containing the Postgres Pod's IP.

**⚠️ If the EndpointSlice is empty**, one of two things is true:

1. The selector doesn't match the Pod labels — compare `kubectl get svc postgres-db -o jsonpath='{.spec.selector}'` against `kubectl get pods --show-labels`
2. The Pod exists but isn't Ready — a Pod failing its readiness probe is excluded from endpoints. Check `kubectl get pods` for `1/1` vs `0/1`.

That second case is the one to remember. Readiness failure and selector mismatch produce the identical symptom of an empty EndpointSlice, and people reflexively assume the selector.

### 7.1 — The Name Is Load-Bearing

`postgres-db` isn't cosmetic. It's the string in `DB_HOST` from Step 4, the `-h` argument in Step 9's init container, and the DNS name Step 11 resolves. Rename the Service and three other things break.

Confirm the chain is consistent right now:

```bash
echo "Service name : $(kubectl get svc postgres-db -o jsonpath='{.metadata.name}')"
echo "DB_HOST      : $(kubectl get cm python-api-config -o jsonpath='{.data.DB_HOST}')"
```

Two minutes here beats debugging `Name or service not known` in Step 9.

### 7.2 — [Deep Dive] Named Ports

Both the container port and the Service port carry `name: postgres`. This lets `targetPort` reference the name instead of the number:

```yaml
ports:
  - port: 5432
    targetPort: postgres      # resolves via the container's port name
```

Change the container's port later and the Service follows automatically. Small thing, but it removes a class of drift.

---

## Step 8 — Confirm Postgres Is Genuinely Healthy

Don't skip this. The whole design of the sub-lab is one variable at a time.

```bash
kubectl rollout status deployment/postgres
kubectl get deploy postgres
kubectl get pods -l app=postgres -o wide
kubectl get endpointslices -l kubernetes.io/service-name=postgres-db \
  -o jsonpath='{.items[*].endpoints[*].addresses}'; echo
```

**Pass conditions — all four:**

| Check | Required |
|---|---|
| Deployment | `READY 1/1`, `AVAILABLE 1` |
| Pod | `READY 1/1`, `STATUS Running`, `RESTARTS 0` |
| EndpointSlice | contains the Pod's IP |
| Probes | no failure events |

The restart count matters. `1/1 Running` with `RESTARTS 4` means the liveness probe has been killing it — probably a probe that's too aggressive rather than a real fault.

Check events explicitly:

```bash
kubectl describe pod -l app=postgres | sed -n '/Events:/,$p'
```

**Expect:** `Scheduled`, `Pulled`, `Created`, `Started`. Any `Unhealthy` entries mean a probe is failing.

### 8.1 — Prove It From Another Pod

The real test is reachability through the Service, not from inside the Pod itself:

```bash
kubectl run pg-probe --rm -it --image=postgres:16-alpine --restart=Never -- \
  pg_isready -h postgres-db -p 5432
```

This starts a temporary Pod named `pg-probe` using the `postgres:16-alpine` image only because that image contains the `pg_isready` client tool. `pg_isready` is an official PostgreSQL utility — it checks whether a PostgreSQL server is accepting connections.

**Expect:** `postgres-db:5432 - accepting connections`

This exercises the full path — CoreDNS resolves the name, kube-proxy DNATs the ClusterIP, the packet crosses the CNI network to the Pod. If this works, Step 9's init container will work.

Remember to exit cleanly rather than `Ctrl-C`, or you'll orphan the Pod like the `tmp-shell` in 3.1.

---

## Step 9 — python-api Deployment With an Init Container

The densest step. Read the manifest, then the notes.

### 9.1 — The Manifest

```bash
cat > ~/lab3/msa/07-python-api-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: python-api
  labels:
    app: python-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: python-api
  template:
    metadata:
      labels:
        app: python-api
    spec:
      # Runs to completion BEFORE the main container starts.
      # Replaces Compose's: depends_on: { condition: service_healthy }
      #
      # Before starting the Python API container, run a small helper container
      # that checks whether Postgres is reachable at postgres-db:5432.
      # It does not start a new Postgres database.
      initContainers:
        - name: wait-for-postgres
          image: postgres:16-alpine
          imagePullPolicy: IfNotPresent
          command:
            - sh
            - -c
            - |
              echo "Waiting for postgres-db:5432 ..."
              until pg_isready -h postgres-db -p 5432 -q; do
                echo "  not ready, retrying in 2s"
                sleep 2
              done
              echo "postgres-db is accepting connections"

      containers:
        - name: python-api
          image: python-api:0.1.0
          imagePullPolicy: IfNotPresent      # required: image is kind-loaded, not in a registry
          ports:
            - name: http
              containerPort: 8001            # <-- CHANGE to your app's real port

          envFrom:
            - configMapRef:
                name: python-api-config

          env:
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: username              # same key as Postgres, different env var name
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password

          readinessProbe:
            httpGet:
              path: /health                  # <-- CHANGE if different
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3

          livenessProbe:
            httpGet:
              path: /health
              port: http
            initialDelaySeconds: 20
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
EOF
```

Before applying, fix the two marked values using what you found in Step 0.4.

### 9.2 — Watch the Init Container in Action

Start the watch first, so you catch the phase transition:

```bash
kubectl get pods -l app=python-api -w
```

Then in another session:

```bash
kubectl apply -f ~/lab3/msa/07-python-api-deployment.yaml
```

**Expect in the watch window:**

```
python-api-xxx   0/1   Pending             0s
python-api-xxx   0/1   Init:0/1            1s      <- init container running
python-api-xxx   0/1   PodInitializing     4s      <- init done, main starting
python-api-xxx   0/1   Running             6s      <- process up, not yet Ready
python-api-xxx   1/1   Running             11s     <- readiness probe passed
```

`Init:0/1` means "zero of one init containers complete". Since Postgres is already up, it'll pass in a second or two.

Read the init container's own logs — a separate stream from the main container:

```bash
kubectl logs -l app=python-api -c wait-for-postgres
```

### 9.3 — See It Actually Block

The above went too fast to feel. Force the wait:

```bash
kubectl scale deployment postgres --replicas=0
kubectl rollout restart deployment/python-api

kubectl get pods -l app=python-api            # stuck at Init:0/1
kubectl logs -l app=python-api -c wait-for-postgres -f   # "not ready, retrying" every 2s
```

```
Waiting for postgres-db:5432 ...
postgres-db is accepting connections
```

Leave it looping for 30 seconds. Then bring Postgres back:

```bash
kubectl scale deployment postgres --replicas=1
```

Watch the init container succeed and the main container start, unattended.

**Why it matters:** that is what "the main container never even starts" means. The application process was never launched, so it never had a chance to crash on a failed DB connection. Compare with what happens without an init container — the app starts, fails to connect, exits, `CrashLoopBackOff`, and Kubernetes backs off exponentially (10s, 20s, 40s... up to 5 minutes). Your app might sit unavailable for minutes after the database recovered, purely because of backoff timing.

An init container converts a crash loop into an orderly wait.

### 9.4 — Init Container Semantics Worth Knowing

- They run sequentially, in list order. Each must exit 0 before the next starts.
- If one fails, the Pod restarts and all init containers run again from the start. So they must be idempotent.
- They run again on every Pod restart, not just first creation.
- Probes don't apply to them. They're expected to terminate.
- They can have different images and different volume mounts than the main container — commonly used for database migrations, config templating, or fetching secrets.
- `kubectl logs <pod>` shows the main container. Init logs need `-c <init-container-name>`.

### ⚠️ 9.5 — What pg_isready Does Not Check

`pg_isready` verifies the server accepts TCP connections. It does not verify:

- your credentials are valid
- the database named in `DB_NAME` exists
- any tables or schema exist

So the init container can pass while python-api still fails with `password authentication failed` or `database "appdb" does not exist`. If that happens, the failure surfaces in the main container's logs, not the init container's — and Gotcha 4 (mismatched DB names) is the usual cause.

**[Deep dive]** A stricter gate, if you want one:

```yaml
command:
  - sh
  - -c
  - |
    until pg_isready -h postgres-db -p 5432 -q; do sleep 2; done
    until PGPASSWORD="$PGPASS" psql -h postgres-db -U "$PGUSER" -d "$PGDB" -c 'SELECT 1' >/dev/null 2>&1; do
      echo "  server up but not accepting our credentials/database yet"
      sleep 2
    done
env:
  - name: PGUSER
    valueFrom: { secretKeyRef: { name: db-credentials, key: username } }
  - name: PGPASS
    valueFrom: { secretKeyRef: { name: db-credentials, key: password } }
  - name: PGDB
    valueFrom: { configMapKeyRef: { name: python-api-config, key: DB_NAME } }
```

This tests the actual connection your app will make. Note the last entry — `configMapKeyRef` is the single-key counterpart to `envFrom`, and this is a natural place to use it.

### 9.6 — Why port: http in the Probes

The probes reference the port by name, defined once in `ports:`. Change the port number in one place and both probes follow. Numbers work too, but they duplicate the value in three places, and probe/port drift is a real failure mode.

### 9.7 — Verify the Wiring

```bash
POD=$(kubectl get pod -l app=python-api -o jsonpath='{.items[0].metadata.name}')

kubectl exec "$POD" -- env | grep -E '^DB_' | sort
kubectl logs "$POD" --tail=30
kubectl describe pod "$POD" | sed -n '/Init Containers:/,/^Conditions:/p'
```

**Expect from the env dump:** `DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_SSLMODE`, `DB_CONNECT_TIMEOUT` (from the ConfigMap) plus `DB_USER` and `DB_PASSWORD` (from the Secret) — seven variables, two sources, one flat namespace.

The `describe` output shows the init container with `State: Terminated`, `Reason: Completed`, `Exit Code: 0`. That's the checklist item about the init container completing before the main container started.

---

## Step 10 — python-api Service

```bash
cat > ~/lab3/msa/08-python-api-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: python-api
  labels:
    app: python-api
spec:
  type: ClusterIP
  selector:
    app: python-api
  ports:
    - name: http
      port: 80
      targetPort: http        # named port from the Deployment
      protocol: TCP
EOF

kubectl apply -f ~/lab3/msa/08-python-api-service.yaml

kubectl get svc
kubectl get endpointslices -l kubernetes.io/service-name=python-api
```

Note `port: 80` with `targetPort: http` (which resolves to `8000`). Clients use the conventional port; the app keeps its own. This is the `--port` / `--target-port` distinction from 3.1's Step 4.3, now doing something useful.

The Service is named `python-api` — the same name as the Deployment. That's legal; they're different resource types and names only collide within a type. It's also conventional, and it's what Sub-lab 3.3's Ingress will route to.

### 10.1 — Test Through the Service

```bash
kubectl run curl-test --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -sS -m 5 http://python-api/health; echo
```

**Expect:** your health endpoint's JSON.

That short name works because the caller is in the same namespace. Full form:

```bash
kubectl run curl-test --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -sS -m 5 http://python-api.multi-service-app.svc.cluster.local/health; echo
```

---

## Step 11 — Verify Pod-to-Pod DNS

### ⚠️ Your App Image Probably Has No nslookup

Slim Python images ship no `dnsutils`, no busybox, often no `curl`. Try in order:

```bash
POD=$(kubectl get pod -l app=python-api -o jsonpath='{.items[0].metadata.name}')

# 1. getent — part of glibc, present on most Debian-based images
kubectl exec "$POD" -- getent hosts postgres-db

# 2. Python itself — guaranteed present in a Python image
kubectl exec "$POD" -- python3 -c \
  "import socket; print(socket.gethostbyname('postgres-db'))"

# 3. The full FQDN
kubectl exec "$POD" -- python3 -c \
  "import socket; print(socket.gethostbyname('postgres-db.multi-service-app.svc.cluster.local'))"
```

**Expect:** an IP in `10.96.0.0/16` — the Service's ClusterIP, not a Pod IP. That distinction matters: DNS resolves to the stable Service address, and kube-proxy handles the hop to a real Pod afterward.

Confirm it matches:

```bash
kubectl get svc postgres-db -o jsonpath='{.spec.clusterIP}'; echo
```

### 11.1 — Look at How DNS Is Configured

```bash
kubectl exec "$POD" -- cat /etc/resolv.conf
```

**Expect:**

```
nameserver 10.96.0.10
search multi-service-app.svc.cluster.local svc.cluster.local cluster.local
options ndots:5
```

- `nameserver 10.96.0.10` — CoreDNS's ClusterIP, written by the kubelet at Pod creation
- `search` — why the bare name `postgres-db` works: the resolver appends each suffix in turn
- `ndots:5` — any name with fewer than 5 dots gets the search suffixes tried first, before being treated as absolute

**[Deep dive]** `ndots:5` is a known performance footgun. Resolving `api.github.com` (2 dots, under 5) means the resolver first tries `api.github.com.multi-service-app.svc.cluster.local`, then `...svc.cluster.local`, then `...cluster.local`, getting NXDOMAIN each time, before finally trying the real name. Four queries instead of one, for every external hostname.

Fix for external-heavy workloads — a trailing dot makes a name absolute and skips the search path:

```python
requests.get("https://api.github.com./v3/...")   # note the dot after com
```

Or set `dnsConfig.options` on the Pod to lower `ndots`. Not needed today; worth recognising when a service mysteriously has slow outbound calls.

### 11.2 — Test a Full Connection, Not Just Resolution

DNS resolving proves nothing about whether the port is open:

```bash
kubectl exec "$POD" -- python3 -c "
import socket
s = socket.create_connection(('postgres-db', 5432), timeout=5)
print('TCP connect to postgres-db:5432 OK')
s.close()"
```

If DNS resolves but this fails, the problem is the Service's endpoints or the Pod's readiness — not DNS.

### 11.3 — Contrast With Lab 02

| | Docker Compose | Kubernetes |
|---|---|---|
| Resolver | Docker's embedded DNS at `127.0.0.11` | CoreDNS Pods at a ClusterIP |
| Name resolves to | the container's IP directly | the Service's ClusterIP |
| Load balancing | round-robin DNS if replicated | kube-proxy iptables DNAT |
| Scope | the Docker network | the whole cluster, namespace-scoped names |

The important structural difference is the middle row. Compose gives you a name for a container. Kubernetes gives you a name for a Service, which is an abstraction over a changing set of Pods. That indirection is why scaling python-api to 5 replicas in 3.3 will require zero configuration changes.

---

## Step 12 — Verify End-to-End

### 12.1 — Port-Forward

```bash
kubectl port-forward svc/python-api 8080:80
```

Leave running. In a second SSH session:

```bash
curl -sS http://localhost:8080/health | python3 -m json.tool
curl -sS http://localhost:8080/api/db  | python3 -m json.tool
```

**Expect:** `/api/db` reports `db_status: connected` and a heartbeat count.

### 12.2 — Watch the Heartbeat Climb

```bash
for i in $(seq 1 5); do
  curl -sS http://localhost:8080/api/db
  echo
  sleep 2
done
```

The count should increase — proving the app is doing real round trips to Postgres, not returning a cached or hardcoded value.

### 12.3 — From the Windows Workstation

Same options as 3.1's Step 4.6:

**SSH tunnel (recommended):**

```powershell
ssh -L 8080:localhost:8080 kemel@172.31.17.54
```

Then browse `http://localhost:8080/api/db`.

**Or bind to all interfaces:**

```bash
kubectl port-forward --address 0.0.0.0 svc/python-api 8080:80
```

Then browse `http://172.31.17.54:8080/api/db`.

### 12.4 — Prove the Data Survives a Pod Restart

The PVC's whole purpose, tested in 30 seconds:

```bash
curl -sS http://localhost:8080/api/db          # note the count

kubectl delete pod -l app=postgres              # Deployment recreates it
kubectl rollout status deployment/postgres
```

python-api's liveness probe may fail during the gap and restart it. Wait for both to be Ready, restart the port-forward, then:

```bash
curl -sS http://localhost:8080/api/db          # count continued, did not reset
```

**Why it matters:** the container was destroyed and rebuilt from a pristine image. The data survived because it lives on the PV, outside the container's writable layer. That's the entire difference between a stateless and a stateful workload, demonstrated rather than described.

**[Deep dive]** Try the same with the PVC removed and you'd get a freshly-initialised database every restart. Don't do it now — you'd lose the data. But that's the failure mode a missing volume produces, and it presents as "my database keeps forgetting things", which people rarely connect to volume configuration.

---

## Step 13 — The ConfigMap Gotcha, on Purpose

### 13.1 — Establish the Baseline

```bash
POD=$(kubectl get pod -l app=python-api -o jsonpath='{.items[0].metadata.name}')
echo "Pod: $POD"
kubectl exec "$POD" -- env | grep DB_CONNECT_TIMEOUT
```

**Expect:** `DB_CONNECT_TIMEOUT=5`

### 13.2 — Change the ConfigMap

```bash
sed -i 's/DB_CONNECT_TIMEOUT: "5"/DB_CONNECT_TIMEOUT: "15"/' \
  ~/lab3/msa/03-python-api-config.yaml

kubectl apply -f ~/lab3/msa/03-python-api-config.yaml
kubectl get cm python-api-config -o jsonpath='{.data.DB_CONNECT_TIMEOUT}'; echo
```

**Expect:** the ConfigMap now says `15`.

### 13.3 — Observe That the Pod Does Not Care

```bash
kubectl exec "$POD" -- env | grep DB_CONNECT_TIMEOUT       # still 5
kubectl get pods -l app=python-api                          # no restart, same AGE
kubectl describe pod "$POD" | sed -n '/Events:/,$p'        # no new events
```

**Expect:** the running Pod still reports `5`. No restart, no event, no warning anywhere.

Wait two minutes and check again. Still `5`. It will never change.

**Why:** environment variables are set when the process starts and are immutable for its lifetime. That's a property of Linux processes, not a Kubernetes shortcoming. The kubelet read the ConfigMap once, at container creation, and injected the values. There is no mechanism — and can be no mechanism — to change them afterward.

This is genuinely dangerous in production. Someone updates a ConfigMap, sees `kubectl get cm` reflect the change, and reasonably concludes it's live. It isn't. Weeks later a node drains, Pods reschedule, and the new config takes effect unexpectedly — a change nobody remembers making, appearing at a moment nobody chose.

### 13.4 — [Deep Dive] The Contrast: Volume-Mounted Config Does Update

Prove it, so the distinction is concrete rather than trusted:

```bash
kubectl create configmap demo-file-config --from-literal=setting.txt=original

kubectl run cm-volume-demo --image=busybox:1.36 --restart=Never \
  --overrides='{
    "spec": {
      "containers": [{
        "name": "cm-volume-demo",
        "image": "busybox:1.36",
        "command": ["sh","-c","while true; do echo -n \"$(date +%T) \"; cat /cfg/setting.txt; echo; sleep 5; done"],
        "volumeMounts": [{"name":"cfg","mountPath":"/cfg"}]
      }],
      "volumes": [{"name":"cfg","configMap":{"name":"demo-file-config"}}]
    }
  }'

kubectl logs -f cm-volume-demo
```

In another session, change it:

```bash
kubectl create configmap demo-file-config --from-literal=setting.txt=UPDATED \
  --dry-run=client -o yaml | kubectl apply -f -
```

Watch the log. Within about 60 seconds the output changes to `UPDATED` — no restart.

Clean up:

```bash
kubectl delete pod cm-volume-demo
kubectl delete configmap demo-file-config
```

| Mode | Live update | Why |
|---|---|---|
| `envFrom` / `env.valueFrom` | Never | Process environment is immutable |
| Volume mount | ~60s | kubelet swaps the file via a symlink |

Note the caveat on the volume side: the file updates, but your application must re-read it. Most don't. So volume mounts give you the possibility of hot reload, not hot reload itself.

The `--dry-run=client -o yaml | kubectl apply -f -` pattern above is worth stealing — it makes `kubectl create` behave idempotently, which plain `create` doesn't (it errors on "already exists").

### 13.5 — Force the Update

```bash
kubectl rollout restart deployment/python-api
kubectl rollout status deployment/python-api

NEWPOD=$(kubectl get pod -l app=python-api -o jsonpath='{.items[0].metadata.name}')
echo "old: $POD"
echo "new: $NEWPOD"
kubectl exec "$NEWPOD" -- env | grep DB_CONNECT_TIMEOUT
```

**Expect:** `DB_CONNECT_TIMEOUT=15`, and a different Pod name.

Note the word `restart` is misleading. It doesn't restart anything — it performs a rolling replacement. Kubernetes has no "restart" verb; the implementation adds an annotation with a timestamp to the Pod template, which changes the template hash, which makes the Deployment create a new ReplicaSet:

```bash
kubectl get deploy python-api -o jsonpath='{.spec.template.metadata.annotations}' | python3 -m json.tool
kubectl get rs -l app=python-api
```

You'll see two ReplicaSets — old at 0 replicas, new at 1. Exactly the mechanism from 3.1's Step 5.6.

Also note the init container ran again on the new Pod:

```bash
kubectl logs "$NEWPOD" -c wait-for-postgres
```

That's the idempotency requirement from 9.4 in practice.

### 13.6 — [Deep Dive] How Production Automates This

The manual restart is fine for a lab and unacceptable at scale — it relies on someone remembering. The standard fix is a checksum annotation on the Pod template:

```yaml
spec:
  template:
    metadata:
      annotations:
        checksum/config: "<sha256 of the ConfigMap contents>"
```

The annotation lives on the Pod template, so changing it changes the template hash, which triggers a rollout automatically. Helm computes it at render time; Kustomize solves the same problem differently with `configMapGenerator`, which appends a content hash to the ConfigMap's name — a changed ConfigMap becomes a new object, so the Deployment's reference changes and a rollout follows.

Do it by hand once, just to see the mechanism:

```bash
SUM=$(kubectl get cm python-api-config -o jsonpath='{.data}' | sha256sum | cut -c1-16)
kubectl patch deployment python-api -p \
  "{\"spec\":{\"template\":{\"metadata\":{\"annotations\":{\"checksum/config\":\"$SUM\"}}}}}"
kubectl rollout status deployment/python-api
```

There's also immutable ConfigMaps (`immutable: true`), which forbid edits entirely and force you to create a new named object. Trades convenience for an audit trail, and improves API server performance at scale by removing the need to watch for changes.

### 13.7 — Restore the Value

```bash
sed -i 's/DB_CONNECT_TIMEOUT: "15"/DB_CONNECT_TIMEOUT: "5"/' \
  ~/lab3/msa/03-python-api-config.yaml
kubectl apply -f ~/lab3/msa/03-python-api-config.yaml
kubectl rollout restart deployment/python-api
kubectl rollout status deployment/python-api
```

Leaving it at 15 would work fine, but keeping the file and the cluster in sync is the habit worth building.

---

## Final State Check

Nothing gets deleted. Confirm what should exist:

```bash
kubectl get all
kubectl get cm,secret,pvc,pv
kubectl get endpointslices
```

**Expected inventory in `multi-service-app`:**

| Type | Name |
|---|---|
| Secret | `db-credentials` |
| ConfigMap | `postgres-config`, `python-api-config` (+ `kube-root-ca.crt`, automatic) |
| PVC | `postgres-pvc` — `Bound` |
| Deployment | `postgres` 1/1, `python-api` 1/1 |
| Service | `postgres-db`, `python-api` |
| Pod | one each, both 1/1 Running, low restart count |

Note `kube-root-ca.crt` — a ConfigMap Kubernetes puts in every namespace automatically, holding the cluster CA certificate. Not yours, don't delete it.

Tidy up any orphaned debug Pods:

```bash
kubectl get pods --field-selector=status.phase=Succeeded
kubectl delete pods --field-selector=status.phase=Succeeded
kubectl get pods -n default
```

Commit your manifests — everything except the Secret:

```bash
cd ~/lab3
cat > .gitignore <<'EOF'
.secrets/
*.secret.yaml
EOF
ls -la ~/lab3/msa/
```

---

## Verification Checklist (Annotated)

| # | Check | Command | Pass condition |
|---|---|---|---|
| 1 | Image on all nodes | `for n in lab3-control-plane lab3-worker lab3-worker2; do docker exec $n crictl images \| grep python-api; done` | 3 hits |
| 2 | Secret + ConfigMaps + PVC | `kubectl get secret,cm,pvc` | all present; PVC `Bound`, not `Pending` |
| 3 | Postgres Ready | `kubectl get deploy postgres` | 1/1, low restarts, no `Unhealthy` events |
| 4 | Init container completed | `kubectl describe pod -l app=python-api \| grep -A6 'Init Containers'` | `Terminated` / `Completed` / `Exit Code: 0` |
| 5 | DNS from the Pod | `kubectl exec <pod> -- python3 -c "import socket;print(socket.gethostbyname('postgres-db'))"` | returns the Service's ClusterIP |
| 6 | End-to-end | `curl localhost:8080/api/db` twice | `db_status: connected`, count climbing |
| 7 | ConfigMap gotcha | Steps 13.1–13.5 | old value persisted until rollout restart |

On item 2: the PVC is `Pending` until a Pod consumes it (Step 5's gotcha). By the end of the lab it must be `Bound`. `Pending` at the finish means the Postgres Pod never scheduled.

## Self-Test

1. Why does `kind load docker-image` exist, and what replaces it on EKS?
2. A Secret and a ConfigMap both end up as env vars in the container. What does the Secret actually buy you?
3. Why is `strategy: Recreate` on the Postgres Deployment and not on python-api?
4. The init container's `pg_isready` passes but python-api logs an authentication error. What did the init container fail to verify?
5. You edit a ConfigMap and nothing happens. Explain why, in terms of Linux processes rather than Kubernetes.
6. `kubectl get endpointslices` shows no addresses for a Service. Name the two distinct causes.
7. Why does resolving `postgres-db` return a `10.96.x.x` address rather than a Pod IP?

---

## Troubleshooting

**`ErrImagePull` / `ImagePullBackOff` on python-api**

```bash
kubectl describe pod -l app=python-api | grep -A5 Events
docker exec lab3-worker crictl images | grep python-api
```

Either the image never loaded (`kind load` again), or `imagePullPolicy` is `Always` because the tag is `:latest`. Set `IfNotPresent`.

**`CreateContainerConfigError`** — almost always a missing ConfigMap/Secret or a wrong key name:

```bash
kubectl describe pod <pod> | grep -A5 Events
kubectl get secret db-credentials -o jsonpath='{.data}' | python3 -m json.tool
```

The message names the missing key. Check for a typo — `key: username` vs `key: user`.

**Postgres CrashLoopBackOff**

```bash
kubectl logs -l app=postgres --previous --tail=50
```

- `"directory not empty"` → the `PGDATA` fix from 6.2 didn't apply
- `"role does not exist"` → the PVC has data from a previous run with different credentials. The Postgres image only honours `POSTGRES_USER`/`POSTGRES_PASSWORD` on first initialisation. To start clean:

```bash
kubectl delete deployment postgres
kubectl delete pvc postgres-pvc
kubectl apply -f ~/lab3/msa/04-postgres-pvc.yaml
kubectl apply -f ~/lab3/msa/05-postgres-deployment.yaml
```

This destroys the data. Fine in a lab.

**PVC stuck Pending after the Pod exists**

```bash
kubectl describe pvc postgres-pvc | tail -10
kubectl get pods -n local-path-storage
kubectl logs -n local-path-storage -l app=local-path-provisioner --tail=30
```

If the provisioner Pod is unhealthy, the PVC can never bind.

**Pod stuck `Init:0/1`**

```bash
kubectl logs <pod> -c wait-for-postgres
```

Working as designed if Postgres isn't Ready. If Postgres is Ready, check DNS and endpoints:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=postgres-db
kubectl run t --rm -it --image=busybox:1.36 --restart=Never -- nslookup postgres-db
```

**`Readiness probe failed: connection refused`** — wrong port. Find the real one:

```bash
kubectl exec <pod> -- sh -c 'cat /proc/net/tcp' | head
kubectl logs <pod> | head -20      # most frameworks log their listen address
```

Then fix `containerPort` and reapply.

**`Readiness probe failed: HTTP 404`** — right port, wrong path. Verify the endpoint exists:

```bash
kubectl exec <pod> -- python3 -c \
  "import urllib.request; print(urllib.request.urlopen('http://127.0.0.1:8000/health').read())"
```

**python-api restarting repeatedly with `1/1 Running`** — liveness probe too aggressive, or the app is genuinely slow. Raise `initialDelaySeconds`, or add a `startupProbe` (see 6.4).

**`kubectl port-forward` drops constantly** — usually the target Pod is being restarted by a failing liveness probe. Check `RESTARTS` before blaming the tunnel.

---

## Reference Card — New in 3.2

```bash
# Images
kind load docker-image <img>:<tag> --name lab3
docker exec lab3-worker crictl images

# ConfigMaps & Secrets
kubectl create configmap <n> --from-literal=K=V
kubectl create configmap <n> --from-env-file=./app.env
kubectl create secret generic <n> --from-literal=K=V
kubectl create secret generic <n> --from-file=K=./file
kubectl get secret <n> -o jsonpath='{.data.K}' | base64 -d
kubectl create cm <n> --from-literal=K=V --dry-run=client -o yaml | kubectl apply -f -

# Storage
kubectl get pvc,pv,storageclass
kubectl describe pvc <n>

# Multi-container Pods
kubectl logs <pod> -c <container>
kubectl logs <pod> -c <init-container>
kubectl exec -it <pod> -c <container> -- sh
kubectl describe pod <pod> | grep -A8 'Init Containers'

# Rollouts
kubectl rollout restart deployment/<n>
kubectl rollout status  deployment/<n>
kubectl rollout history deployment/<n>
kubectl rollout undo    deployment/<n>

# Probing from outside a Pod
kubectl run t --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- curl -sS http://<svc>/path
kubectl run t --rm -it --image=postgres:16-alpine --restart=Never -- pg_isready -h <svc> -p 5432
kubectl port-forward svc/<n> 8080:80
```

### YAML Snippets You'll Reuse Constantly

```yaml
# All ConfigMap keys → env vars
envFrom:
  - configMapRef:
      name: my-config

# One Secret key → a renamed env var
env:
  - name: DB_PASSWORD
    valueFrom:
      secretKeyRef:
        name: db-credentials
        key: password

# One ConfigMap key → a renamed env var
env:
  - name: TIMEOUT
    valueFrom:
      configMapKeyRef:
        name: my-config
        key: DB_CONNECT_TIMEOUT

# ConfigMap as files (this one DOES hot-update)
volumeMounts:
  - name: cfg
    mountPath: /etc/app
volumes:
  - name: cfg
    configMap:
      name: my-config

# PVC mount
volumeMounts:
  - name: data
    mountPath: /var/lib/postgresql/data
volumes:
  - name: data
    persistentVolumeClaim:
      claimName: postgres-pvc

# Init container gate
initContainers:
  - name: wait-for-db
    image: postgres:16-alpine
    command: ["sh","-c","until pg_isready -h postgres-db -p 5432 -q; do sleep 2; done"]
```
