# Lab 02 — Dockerizing a Multi-Service App: React + Python API + Node.js API + PostgreSQL, Behind a Reverse Proxy

## Objective

Carry the routing/traffic concepts from Lab 01 into containers, and use them as the vehicle to build real Docker fluency:

1. Containerize the React/Vite frontend from `kemeldev/multi-service-App`.
2. Containerize the Python API (FastAPI) from the same repo.
3. Containerize the Node.js API (Express) from the same repo.
4. Run PostgreSQL as a container with real, durable persistence.
5. Put a reverse proxy / load balancer container in front of everything, with the same two routing variants explored in Lab 01 (round-robin and path-based) — now expressed as Docker networks, service discovery, and upstream/location blocks instead of VM IPs.

Non-production lab, same philosophy as Lab 01: build it with real-world habits (least-privilege networking, non-root containers, pinned/minimal images, secrets hygiene) so they carry forward.

**Decision locked in this revision — single host.** Unlike Lab 01, every container in this lab runs on one Docker host rather than being spread across three VMs. Splitting containers back across multiple machines would just reintroduce the distro-specific complexity Docker is designed to remove, without teaching anything new about Docker itself. The reverse proxy is not a separate machine — it's just another container on the same host, on the same networks, which is also the idiomatic pattern (and the direct precursor to a Kubernetes Ingress controller later).

**Long-term direction (not part of this lab):** this compose stack is deliberately structured so it can be translated almost 1:1 into Kubernetes manifests afterward — service names → Services, networks → NetworkPolicies, healthchecks → readiness/liveness probes, resource limits → requests/limits, `.env`/secrets → ConfigMaps/Secrets. Multi-host Docker (Swarm overlay networks) is deliberately deferred to a future Lab 03 — see Step 12.

## Environment

| Role | Hostname | IP | OS | Software |
|---|---|---|---|---|
| Docker host (all 5 containers) | `ubuntuserver1.ssa.veeam.local` | 172.31.17.182 | Ubuntu Server | Docker Engine + Compose plugin |
| Control point | Windows workstation | 172.24.209.0/24 | Windows | SSH client + browser |

This reuses the Ubuntu VM from Lab 01 — it already has Docker's usual dependencies satisfied and, per the repo's own README, was previously used as the reachable host for this exact app's database (`DB_HOST=ubuntuserver1.ssa.veeam.local`). The Fedora and RHEL VMs from Lab 01 are not used in this lab; they're earmarked for a future multi-host (Swarm) or Kubernetes lab.

**Scope of "reachable from anywhere":** same as Lab 01 — reachable from anywhere on `172.31.16.0/22`, not the public internet. Only the reverse proxy container publishes a port to the host; `ufw` on Ubuntu scopes that port to the `/22`, exactly as it scoped port 80 in Lab 01 Step 2.

## The App (`kemeldev/multi-service-App`)

Repo: [kemeldev/multi-service-App](https://github.com/kemeldev/multi-service-App) — a 3-tier test app built specifically for exercising ports, connectivity, CORS, and DB reachability.

**Structure:**

```
multi-service-App/
├── README.md
├── docker-compose.db.yml     # existing — Postgres only, superseded by our full stack below
├── db/
│   └── init.sql
├── frontend/                 # React + Vite, dev server on :5173
├── api-python/                # FastAPI, :8001
└── api-node/                  # Express, :8002
```

| Service | Port | Key endpoints | Notes |
|---|---|---|---|
| `frontend` | 5173 (dev) | — | Vite dev server only — for the container we build static and serve via nginx, per Lab 01's "static builds only" rule |
| `api-python` | 8001 | `/`, `/health`, `/api/info`, `/api/db`, `/docs` | FastAPI, writes to `py_heartbeat` table every `HEARTBEAT_SECONDS` |
| `api-node` | 8002 | `/`, `/health`, `/api/info`, `/api/db` | Express, writes to `node_heartbeat` table |
| `postgres` | 5432 | — | `testuser` / `testdb`, both APIs share the instance but never the table |

Two details from the repo that directly shape the Docker build:

- `/health` already exists and never touches the DB — exactly what a container `HEALTHCHECK` wants. No need to add one.
- The frontend reads `VITE_PY_API` / `VITE_NODE_API` at **build time**, not runtime. This is a classic React/Vite-in-Docker gotcha: once `npm run build` runs, those URLs are baked into the static JS bundle — an env var set on `docker run` after the fact does nothing. For this lab, build the frontend image with `VITE_PY_API=/api/py` and `VITE_NODE_API=/api/node` (relative paths), so the browser always calls back through the proxy's own origin. That sidesteps CORS entirely and avoids baking a container IP into the bundle. This is worth calling out explicitly in Step 3 — it's the kind of thing that "works on my machine" and then silently breaks the moment the app moves host.

## Networking

| Network | Driver | Members |
|---|---|---|
| `frontend-net` | user-defined bridge | `edge-proxy`, `react-frontend` |
| `backend-net` | user-defined bridge | `edge-proxy`, `python-api`, `node-api` |
| `db-net` | user-defined bridge | `python-api`, `node-api`, `postgres-db` |

Only `edge-proxy` publishes a port to the host. Everything else is reachable only via container-name DNS on the networks above — the containerized analog of scoping Lab 01's firewall rules to `172.31.16.0/22` instead of `0.0.0.0/0`. (Diagram provided separately in chat.)

### Docker Network Driver Primer — What We Use, and Why We Skip the Rest

Most of Docker's eight network drivers are genuinely the wrong tool for a single-host lab — here's the reasoning, not just the verdict:

| Driver | What it is | In this lab? |
|---|---|---|
| **Bridge (default)** | Docker's built-in single-host NAT network. Every container lands here unless told otherwise; everything can reach everything, no DNS by container name. | Used only for a 2-minute contrast demo in Step 2 — this is why we don't use it for real. |
| **User-defined bridge** | Same driver, but a network you name yourself. Containers on it get real DNS-by-name and only see what they're explicitly attached to. | ✅ Primary driver for the whole lab — the three networks above. |
| **Host** | Container shares the host's network namespace directly — no isolation, no port mapping. | Brief demo only, in Step 2, to feel why it's risky (it's also exactly what caused the nginx-port-80 collision flagged in Step 1). |
| **None** | No networking at all. | Brief demo in Step 2 — a one-off maintenance/backup container that has no business talking to the network. |
| **Macvlan (bridge mode)** | Container gets a real, routable MAC + IP directly on the physical LAN — indistinguishable from another physical host on the wire. | Optional stretch (Step 12) — genuinely interesting here because it would give a container a real `172.31.16.0/22` address, mirroring how Lab 01's VMs got real subnet IPs. Flag: needs the hypervisor's virtual NIC to allow promiscuous mode / MAC spoofing, which not all hypervisors permit for a VM's vNIC — treat as "try it, fall back to conceptual" rather than a guaranteed win. |
| **Macvlan (802.1q trunk)** | Same idea, one physical NIC split into per-VLAN subinterfaces. | Conceptual only — needs a VLAN-tagged switchport we don't have in this lab. |
| **IPvlan L2/L3** | Similar outcome to macvlan (containers get real LAN IPs) but they share the host's MAC address, which plays nicer with switches that block MAC spoofing. | Conceptual only — same real-LAN-IP idea as macvlan without the promiscuous-mode requirement; worth knowing exists as the fallback when macvlan is blocked. |
| **Overlay** | A virtual network spanning multiple Docker hosts, used by Swarm/Kubernetes so containers on different physical machines can talk as if on one network. | Not this lab — it's the natural next thing to learn once you add a second host (Step 12 stretch / future Lab 03). |

**The takeaway to internalize:** user-defined bridge is the correct default for anything single-host, host/none are useful mainly as contrast so you recognize when something is wrong, and macvlan/ipvlan/overlay only start earning their complexity once containers need a real routable identity on the physical network or need to span more than one host.

## Decisions Locked In For This Lab

- **Multi-stage builds everywhere.** Every image has a build stage and a slim runtime stage; no compilers, dev dependencies, or source maps ship in the final image.
- **Non-root containers.** Every service runs as a non-root `USER` (Node and Nginx images already provide one — use it; add one explicitly for the Python image).
- **`.dockerignore` per service** (`node_modules`, `.git`, `.env`, `dist`, `__pycache__`, etc.) — nothing bloats the build context or leaks into an image by accident.
- **Config via environment variables**, loaded through `.env` files and docker compose, never hardcoded. A `.env.example` is committed; the real `.env` is gitignored. The repo's example Postgres password (`1234`) gets replaced before this ever runs anywhere shared.
- **Frontend API URLs baked at build time** as relative paths (`/api/py`, `/api/node`) — see the callout above. This is a deliberate, documented exception to "config via env vars," because Vite's build-time behavior makes a true runtime env var impossible without an extra templating step (out of scope for this lab, worth a footnote if you want to go further later).
- **Named volume for Postgres (`pgdata`)** so data survives container recreation. Removing the container must not remove the data — removing the volume is a separate, deliberate action.
- **Custom user-defined bridge networks**, not the default bridge network — see the primer above.
- **Healthchecks on every service**, using the app's existing `/health` endpoints for the two APIs, so `depends_on` can wait for "actually ready," not just "process started."
- **Resource limits (`cpus`, `mem_limit`) set from day one**, even in a lab — "it only works because nothing is constrained" is a habit we don't want carrying into Kubernetes.
- **Pinned, minimal base images** — alpine/slim variants, explicit version tags, never `:latest`.
- **Naming/tagging convention agreed up front** (`<yourname>/react-frontend:0.1.0`, etc.) so pushing to a registry later is a non-event.
- **TLS, secrets vaulting, and multi-host orchestration (Swarm/K8s) deferred** — same "deferred, not ignored" posture TLS had in Lab 01.

## Planned Steps

### Step 0 — Prep & Docker Fundamentals Refresher

- Install Docker Engine + Compose plugin; confirm with `docker run hello-world`.
- Deliberately review the vocabulary shift from Lab 01: **image vs. container vs. volume vs. network** — this is the main conceptual leap from a bare-metal VM mental model.
- Check we are running Docker, in case it's an older version we can uninstall it and install a newer version:

    ```bash
    docker version
    docker compose version
    docker run hello-world
    ```

### Step 1 — Clear the Decks on the Ubuntu Host

This host ran nginx directly on port 80 in Lab 01 Step 2. Before any container tries to publish port 80, confirm nothing on the host already owns it:

```bash
sudo systemctl status nginx
sudo ss -tulpn | grep ':80\|:443'
```

If nginx (or anything else) is bound to 80/443:

```bash
sudo systemctl stop nginx
sudo systemctl disable nginx
sudo ss -tulpn | grep ':80\|:443'   # confirm empty output
```

Doing this explicitly, as its own step, avoids losing an hour later to "why won't my proxy container bind to port 80" — a genuinely common first-timer Docker networking trap that's really a host-port conflict in disguise.

### Step 2 — Docker Network Driver Walkthrough (Hands-On, Throwaway Containers)

Before building the real stack, feel the difference between drivers using disposable containers — delete everything from this step once done:

- **Default bridge:** `docker run -d --name t1 nginx:alpine` and `docker run -it --rm alpine ping t1` — observe that ping-by-name fails on the default bridge (no automatic DNS).
- **User-defined bridge:** `docker network create demo-net`, run two containers with `--network demo-net`, ping by name — observe it works. This is the "aha" that motivates using custom networks for real, going forward.
- **Host:** `docker run -d --network host --name t2 nginx:alpine` — try to also bind port 80 elsewhere and observe the collision; `docker rm -f t2` immediately after.
- **None:** `docker run -it --rm --network none alpine ping 8.8.8.8` — observe it can't reach anything, by design; this is the correct driver for a container that should never touch the network (e.g. a one-off backup/compression job reading a mounted volume).
- **Clean up:** `docker rm -f t1; docker network rm demo-net`.

### Step 3 — Containerize the React Frontend

- Multi-stage Dockerfile: stage 1 (`node:20-alpine`) runs `npm ci && npm run build` with build args `VITE_PY_API=/api/py` and `VITE_NODE_API=/api/node`; stage 2 (`nginx:alpine`) copies `dist/` into `/usr/share/nginx/html`.
- Call out the build-time-vs-runtime env var gotcha explicitly here — it's the single most likely thing to trip this step up.
- Build and run standalone (`docker run -p 8080:80 ...`) before touching Compose, so failures are isolated to this one image.

### Step 4 — Containerize the Python API (FastAPI, :8001)

- Multi-stage build: install dependencies from `requirements.txt` in a builder stage, copy only the installed packages/venv into a slim `python:3.12-slim` runtime stage.
- `HEALTHCHECK` against the existing `/health` endpoint — no new code needed.
- Read the DB connection info only from environment variables (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`), matching the repo's existing `.env` pattern; test it standalone against a throwaway Postgres container before wiring up Compose.

### Step 5 — Containerize the Node.js API (Express, :8002)

- Same discipline: multi-stage build, `npm ci --omit=dev` in the runtime stage, use the `node` user the base image already provides.
- `HEALTHCHECK` against the existing `/health` endpoint.
- Same environment-variable-only rule for DB connection info (`DB_SSL=false` for this container, per the repo's README).

### Step 6 — PostgreSQL With Real Persistence

- `postgres:16-alpine` + named volume (`pgdata`) mounted at `/var/lib/postgresql/data`.
- Reuse `db/init.sql` from the repo (mounted into `docker-entrypoint-initdb.d/`) to create `testdb`/`testuser` and the two heartbeat tables on first boot — with a real password from your own `.env`, not the repo's example `1234`.
- Prove persistence deliberately: `docker compose down` (no `-v`) → bring it back up → `py_heartbeat`/`node_heartbeat` row counts keep climbing from where they left off. Then `docker compose down -v` → counts reset to zero. Breaking it on purpose is the lesson.

### Step 7 — Wire It Together With Docker Compose + Custom Networks

- One `docker-compose.yml`, five services, the three networks defined above.
- `depends_on` with `condition: service_healthy` so the APIs wait for Postgres to be ready, not just started.
- Verify the segmentation from inside the containers: `react-frontend` cannot reach `postgres-db`; both APIs can. This is the containerized version of the subnet-scoped firewall exercise from Lab 01.

### Step 8 — Reverse Proxy: Two Variants (Mirrors Lab 01 Step 3)

- **Variant A — Path-based routing** (the realistic case for this app): `/` → `react-frontend`, `/api/py/` → `python-api`, `/api/node/` → `node-api`.
  - *(For this Lab 02, doing Variant B is not that important or relevant — we can leave this as a future exercise.)*
- **Variant B — Load-balanced replicas:** `docker compose up --scale node-api=3` and let an upstream block round-robin across replicas. This surfaces a real lesson Lab 01 only hinted at: with more than one instance, the API needs to be stateless, or requests start behaving inconsistently. (This app's heartbeat-per-table design makes that very visible — watch which replica's logs increment.)
- Keep both nginx configs side by side (`nginx.pathbased.conf`, `nginx.roundrobin.conf`) for reference, same as the two vhosts kept in Lab 01.

### Step 9 — Secrets & Configuration Hygiene

- Move the DB password out of a committed `.env` and into Docker Compose secrets (or, at minimum, `.env` + `.gitignore` + a committed `.env.example`, replacing the repo's plaintext example password).
- Discuss explicitly why this step foreshadows Kubernetes `Secret` objects later.

### Step 10 — Observability Basics

- `docker compose logs -f`, and watch each API's own heartbeat logging.
- `docker stats` to watch the resource limits from "Decisions locked in" actually bite.
- Stretch: a lightweight cAdvisor/Prometheus/Grafana stack.

### Step 11 — Image Hygiene & Security Pass

- Run `docker scout cves` (or `trivy image`) against all five images.
- Compare image sizes before/after the multi-stage builds — usually a dramatic before/after.
- Confirm no container runs as root: `docker inspect --format '{{.Config.User}}' <container>`.

### Step 12 (Stretch) — Preview of Orchestration and Real-LAN Networking

- Try `docker stack deploy` against the same Compose file in Swarm mode, just to feel the seam between Compose and an orchestrator — since, like Lab 01, the real long-term direction is Kubernetes next.
- Optional macvlan experiment: attach `edge-proxy` to a macvlan network carved out of `172.31.16.0/22`, so it gets a real routable IP on the subnet instead of a host-published port — directly comparable to how the Lab 01 VMs got real IPs. Good candidate for its own short write-up comparing NAT (bridge + published port) vs. L2 attachment (macvlan).

## Verification Checklist

- `systemctl status nginx` confirms nginx is stopped/disabled on the Ubuntu host before the proxy container starts.
- All five images build with no warnings, on pinned base image versions.
- `docker inspect` confirms every container runs as non-root.
- `react-frontend` cannot resolve/reach `postgres-db`; both APIs can.
- `docker compose down -v` resets both heartbeat table row counts to zero; `down` (no `-v`) then `up` preserves them.
- Variant A: hitting `edge-proxy` on `/`, `/api/py/...`, `/api/node/...` routes to the correct backend and the React UI's status cards go green.
- Variant B: scaling `node-api` to 3 replicas shows round-robin behavior across them.
- No secret values appear in `docker inspect`, image layers, or git history.

---

## Lab Execution

### Step 2

**1. Default bridge — no DNS by container name**

```bash
docker run -d --name t1 nginx:alpine
docker run -it --rm alpine ping -c 2 t1
```

Expected: `ping: bad address 't1'` — it fails. Both containers landed on Docker's built-in default bridge network, and that network does not run an embedded DNS server. Containers on it can only reach each other by IP (`docker inspect t1` to find it), never by name.

```bash
docker network inspect bridge --format '{{range .Containers}}{{.Name}}: {{.IPv4Address}}{{"\n"}}{{end}}'
```

That's the address `ping` would need — annoying to look up every time, and it changes on every restart. That's the motivation for step 2.

**2. User-defined bridge — DNS just works**

```bash
docker network create demo-net
docker run -d --name t3 --network demo-net nginx:alpine
docker run -it --rm --network demo-net alpine ping -c 2 t3
```

Expected: pings succeed, resolving `t3` to its container IP automatically. Same driver under the hood (bridge), but because you named the network yourself, Docker runs its embedded DNS resolver on it. This is the entire reason `frontend-net`/`backend-net`/`db-net` will work later — services will refer to each other as `python-api`, `node-api`, `postgres-db`, never by IP.

```bash
docker network inspect demo-net
```

Look at the `"Containers"` block — `t3` is registered there with its name, which is what makes the DNS lookup possible.

**3. Host network — no isolation, real collision**

```bash
docker run -d --network host --name t2 nginx:alpine
curl -s -o /dev/null -w "%{http_code}\n" http://localhost:80
```

Expected: `200` — nginx answered directly on the host's port 80, no `-p` mapping needed, because the container shares the host's network namespace entirely. Now try running a second container the same way:

```bash
docker run -d --network host --name t4 nginx:alpine
docker logs t4
```

Expected: it exits immediately with an "address already in use" error — nothing stops two `--network host` containers from fighting over the same port, because there's no network isolation between them or the host. This is exactly the class of bug Step 1 is designed to prevent for the real proxy.

Clean up immediately:

```bash
docker rm -f t2 t4
```

**4. None — no networking at all**

```bash
docker run -it --rm --network none alpine ping -c 2 8.8.8.8
```

Expected: `ping: sendto: Network unreachable` — the container has a loopback interface and nothing else. This is the correct driver for something that should never touch the network by design — a one-off job that only reads/writes a mounted volume (a backup or compression task, for example), where "can't accidentally phone home" is a feature, not a bug.

**5. Clean up everything from this step**

```bash
docker rm -f t1 t3
docker network rm demo-net
docker ps -a
docker network ls
```

### Step 3

**1. Get the repo onto the Ubuntu host**

```bash
cd ~
git clone https://github.com/kemeldev/multi-service-App.git
cd multi-service-App/frontend
```

**2. Check the toolchain requirements before picking a base image**

When you containerize a React app, you shouldn't randomly pick `node:20-alpine`. You first check the project files to see if the app requires a specific Node.js version.

```bash
cat package.json | grep -A3 '"engines"'
cat .nvmrc 2>/dev/null
cat package.json | grep '"build"\|"vite"'
```

If there's no `engines` field, Vite + React 19 (per the repo's README) wants Node 18+; `node:20-alpine` covers that comfortably. If you find a stricter constraint, adjust the tag in the Dockerfile below accordingly.

**3. Write `.dockerignore`**

This keeps `node_modules`, git history, and any local `.env` out of the build context entirely — smaller context, faster builds, and no risk of your local `.env` leaking into the image.

```bash
cat > .dockerignore << 'EOF'
node_modules
dist
.git
.env
.env.local
npm-debug.log*
EOF
```

**4. Write the Dockerfile**

This React app is built with Vite, so the final production output is static files: HTML, CSS, and JavaScript. Because of that, the final container does not need to run Node.js. It only needs a lightweight web server to serve the static files.

We use a multi-stage Docker build:

1. **Build stage** — uses Node.js to install dependencies and build the React/Vite app.
2. **Runtime stage** — uses Nginx to serve the already-built static files.

One design change from the original draft, worth calling out: the frontend container does not need its own nginx `location /api/` proxy rule. Once `edge-proxy` is in front of everything (Step 8), the browser only ever talks to the proxy's address — for `/` and for `/api/py`, `/api/node`. The `react-frontend` container just serves static files; it never needs to know the APIs exist.

We're also switching to `nginxinc/nginx-unprivileged` instead of plain `nginx:alpine`. Binding to port 80 requires root; the unprivileged image listens on 8080 by default and runs as a non-root user out of the box — satisfying the "no root containers" rule without extra work.

Create a file named `Dockerfile` inside the frontend directory:

```dockerfile
# ---- build stage ----
FROM node:20-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm ci
# (npm ci is better for Docker builds because it installs the exact
# dependency versions from package-lock.json.)

COPY . .

# Vite bakes these into the JS bundle at build time — see Lab notes on
# why this can't be a runtime env var. Both point through the proxy,
# same-origin, so there's no CORS to configure anywhere.

# ARG values are build-time inputs.
# These lines mean: if no value is provided during docker build, use
# /api/py and /api/node as the default API paths.
# These values can be overridden when building the image:
ARG VITE_PY_API=/api/py
ARG VITE_NODE_API=/api/node

# These lines convert the Docker build arguments into environment variables.
ENV VITE_PY_API=$VITE_PY_API
ENV VITE_NODE_API=$VITE_NODE_API

RUN npm run build

# ---- runtime stage ----
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
```

The default nginx config in that image already serves static files correctly on 8080 — no custom `nginx.conf` needed yet. (If the app uses client-side routing later and you see 404s on refresh, that's when a `try_files $uri /index.html;` config gets added — not needed for this app today.)

```
docker build --build-arg
        ↓
Dockerfile ARG
        ↓
Dockerfile ENV
        ↓
npm run build
        ↓
Vite
        ↓
Final JavaScript bundle
```

**5. Build the image**

```bash
docker build \
  --build-arg VITE_PY_API=/api/py \
  --build-arg VITE_NODE_API=/api/node \
  -t react-frontend:0.1.0 \
  .
```

**6. Verify build-time vars actually landed in the bundle**

Quick sanity check that the ARG → ENV → Vite chain worked, before you spend time debugging it later inside Compose:

```bash
docker run --rm react-frontend:0.1.0 sh -c "grep -r '/api/py' /usr/share/nginx/html/assets/*.js | head -1"
```

You should see a match. If you get nothing, the build args weren't picked up — double check the `ARG`/`ENV` lines above and rebuild with `--no-cache`.

Or this command:

```bash
docker run --rm react-frontend:0.1.0 sh -c "grep -rho '/api/py' /usr/share/nginx/html/assets/*.js | head -1"
```

This checks whether the value `/api/py` was successfully written into the built JavaScript files.

- `sh`: starts a shell inside the container.
- `-c`: means "run the following text as a shell command" — `sh -c "some command here"`.
- `|`: the pipe takes the output from the command on the left and sends it to the command on the right (search for `/api/py`, then send the results to `head -1`).

**7. Run it standalone and verify**

```bash
docker run -d --name react-frontend-test -p 8080:8080 react-frontend:0.1.0
curl -I http://localhost:8080
```

Expect `HTTP/1.1 200 OK`. Then from your Windows workstation, browse to `http://172.31.17.182:8080` and confirm the page loads. The status cards will show red/unreachable right now — that's expected, since `python-api` and `node-api` don't exist yet. We're only proving the static frontend serves correctly.

**8. Confirm non-root**

```bash
docker inspect --format '{{.Config.User}}' react-frontend-test
```

Should show something other than empty/root (the unprivileged image sets this already).

**9. Clean up the standalone test**

```bash
docker rm -f react-frontend-test
```

### Step 4

**1. Move into the API folder**

```bash
cd ~/multi-service-App/api-python
```

**2. Check the toolchain requirements**

```bash
cat requirements.txt
```

`requirements.txt` is usually created by the developer, not automatically by Python. A developer installs packages, then runs `pip freeze > requirements.txt`, which writes installed package versions into the file. These are the external Python packages this app needs in order to run:

- `fastapi==0.118.0` — the web API framework.
- `uvicorn[standard]==0.37.0` — the web server that runs the FastAPI app (FastAPI defines the application, but something has to actually listen on a port and serve HTTP traffic).
- `psycopg[binary]==3.2.10` — the PostgreSQL driver.
- `python-dotenv==1.1.1` — loads environment variables from a `.env` file.

```bash
python3 --version   # just for reference, doesn't matter what the host has
grep -i "python_requires\|python-version" * -r 2>/dev/null
```

Some Python packages install easily (`fastapi`, `python-dotenv` — mostly Python code), but some talk to system libraries or contain optimized C/Rust code. PostgreSQL drivers are a common example (`psycopg2`, `psycopg2-binary`, `psycopg[binary]`, `asyncpg`). Those packages may need extra tools when being installed, such as `gcc`, `make`, Python development headers, PostgreSQL client libraries, or `libpq` development files. Those tools are called compiler tooling or build dependencies.

**3. Write `.dockerignore`**

```bash
cat > .dockerignore << 'EOF'
__pycache__
*.pyc
.venv
.env
.env.local
.git
EOF
```

**4. Write the Dockerfile**

Same multi-stage discipline as the frontend, adapted for Python: build into a virtual environment in the build stage, copy only the finished venv into a slim runtime stage, run as a non-root user, and healthcheck against the app's existing `/health` endpoint using Python itself rather than installing `curl` (one less package in the final image, smaller attack surface — a small thing, but it's the kind of habit worth building now).

**Build stage:**
- Uses Python
- Installs compiler tools
- Creates a virtual environment
- Installs `requirements.txt` packages

**Runtime stage:**
- Uses Python
- Creates a non-root user
- Copies the finished virtual environment
- Copies the app code
- Runs the app

```dockerfile
# ---- build stage ----
FROM python:3.12-slim AS build
WORKDIR /app

# Build tools for any package that needs to compile (e.g. psycopg2 from source).
# Lives only in this stage — never ships in the final image.
RUN apt-get update && apt-get install -y --no-install-recommends gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/*
# gcc: a C compiler. Some Python packages include C code and need a compiler during installation.
# libpq-dev: provides PostgreSQL development libraries and headers.
# --no-install-recommends: install only the required packages, not extra recommended ones.
# rm -rf /var/lib/apt/lists/*: removes package list cache files after installation.

RUN python -m venv /opt/venv
# This creates a Python virtual environment inside the image.
ENV PATH="/opt/venv/bin:$PATH"
# This modifies PATH so /opt/venv/bin comes first, since we created a
# virtual environment there.

COPY requirements.txt .
# This installs the packages listed in requirements.txt into the virtual environment.
# --no-cache-dir: do not keep downloaded package cache files.
RUN pip install --no-cache-dir -r requirements.txt

# ---- runtime stage ----
FROM python:3.12-slim
# This is a new clean image. It does not contain the build tools installed earlier.
WORKDIR /app

# Create a non-root user: a system group named "app", a system user named
# "app", and puts the user "app" into the group "app".
# Why? By default, containers often run as root unless told otherwise.
RUN addgroup --system app && adduser --system --ingroup app app

# Copy the completed virtual environment from the build stage
COPY --from=build /opt/venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

COPY . .

# Switch to the non-root user
USER app

EXPOSE 8001

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD python -c "import urllib.request,sys; sys.exit(0) if urllib.request.urlopen('http://localhost:8001/health').status==200 else sys.exit(1)"

CMD ["python", "main.py"]
```

**5. Build the image**

```bash
docker build -t python-api:0.1.0 .
```

The dot `.` means "use the current folder as the build context." The build context is the folder Docker uses when building the image. If you are inside `~/multi-service-App/api-python`, Docker will use `/home/kemel/multi-service-App/api-python`.

**6. Test it standalone against a throwaway Postgres — isolate the DB variable before Compose**

Create a temporary network and Postgres container matching the repo's expected credentials. `-e` means: set an environment variable inside the container.

```bash
docker network create test-net

docker run -d --name test-pg --network test-net \
  -e POSTGRES_USER=testuser \
  -e POSTGRES_PASSWORD=changeme123 \
  -e POSTGRES_DB=testdb \
  postgres:16-alpine
```

Give it a few seconds to initialize, then run the API on the same network:

```bash
docker run -d --name test-python-api --network test-net -p 8001:8001 \
  -e DB_HOST=test-pg \
  -e DB_PORT=5432 \
  -e DB_NAME=testdb \
  -e DB_USER=testuser \
  -e DB_PASSWORD=changeme123 \
  -e DB_SSLMODE=disable \
  -e DB_CONNECT_TIMEOUT=3 \
  python-api:0.1.0
```

Notice `DB_HOST=test-pg` — that's the container name, resolved by Docker's embedded DNS because both containers are on the same user-defined bridge network (`test-net`). This is Step 2's lesson landing in the real project.

**7. Verify**

```bash
curl -s http://localhost:8001/health
curl -s http://localhost:8001/api/db | python3 -m json.tool
```

`/health` should return `healthy` immediately. `/api/db` should show `db_status connected`, with a live `NOW()` timestamp and `py_heartbeat` row count starting to climb. From the workstation, `http://172.31.17.182:8001/` should show the FastAPI HTML status page too.

**8. Confirm the healthcheck and non-root are actually working**

```bash
docker inspect --format '{{.State.Health.Status}}' test-python-api
docker inspect --format '{{.Config.User}}' test-python-api
```

First should settle on `healthy` after a few checks; second should show `app`, not empty/root.

**9. Clean up**

```bash
docker rm -f test-python-api test-pg
docker network rm test-net
```

### Step 5

**1. Move into the API folder**

```bash
cd ~/multi-service-App/api-node
```

**2. Check the toolchain requirements**

```bash
cat package.json | grep -A3 '"engines"'
cat package.json | grep '"start"\|"main"'
```

`node:20-alpine` should cover a typical Express app comfortably; adjust the tag if `engines` says otherwise.

**3. Write `.dockerignore`**

```bash
cat > .dockerignore << 'EOF'
node_modules
.env
.env.local
.git
npm-debug.log*
EOF
```

**4. Write the Dockerfile**

Same shape as the Python one: build stage installs everything, runtime stage keeps only production dependencies, runs as the non-root `node` user the official image already ships with (no need to create one, unlike the Python image), and healthchecks against the existing `/health` endpoint using Node itself rather than pulling in `curl`.

```dockerfile
# ---- build stage ----
FROM node:20-alpine AS build
WORKDIR /app

COPY package*.json ./
RUN npm ci

COPY . .

# ---- runtime stage ----
FROM node:20-alpine
WORKDIR /app

ENV NODE_ENV=production

COPY package*.json ./
RUN npm ci --omit=dev

COPY --from=build /app .

USER node

EXPOSE 8002

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD node -e "require('http').get('http://localhost:8002/health', res => process.exit(res.statusCode === 200 ? 0 : 1)).on('error', () => process.exit(1))"

CMD ["node", "server.js"]
```

Check `package.json`'s `"main"` field before building — if the entrypoint isn't `index.js` (could be `server.js`, `app.js`, etc.), update the `CMD` line to match.

**5. Build the image**

```bash
docker build -t node-api:0.1.0 .
```

**6. Test it standalone against a throwaway Postgres**

Same pattern as Step 4 — isolate the DB connection before Compose ties everything together:

```bash
docker network create test-net

docker run -d --name test-pg --network test-net \
  -e POSTGRES_USER=testuser \
  -e POSTGRES_PASSWORD=changeme123 \
  -e POSTGRES_DB=testdb \
  postgres:16-alpine
```

Give it a few seconds to initialize, then run the API:

```bash
docker run -d --name test-node-api --network test-net -p 8002:8002 \
  -e DB_HOST=test-pg \
  -e DB_PORT=5432 \
  -e DB_NAME=testdb \
  -e DB_USER=testuser \
  -e DB_PASSWORD=changeme123 \
  -e DB_SSL=false \
  node-api:0.1.0
```

Again — `DB_HOST=test-pg` resolves via Docker's embedded DNS on the shared `test-net` network, same mechanism as the Python API.

**7. Verify**

```bash
curl -s http://localhost:8002/health
curl -s http://localhost:8002/api/db | python3 -m json.tool
```

`/api/db` should show `db_status connected` and the `node_heartbeat` row count climbing. From the workstation, `http://172.31.17.182:8002/` should show Express's own HTML status page.

**8. Confirm healthcheck and non-root**

```bash
docker inspect --format '{{.State.Health.Status}}' test-node-api
docker inspect --format '{{.Config.User}}' test-node-api
```

Should settle on `healthy`, and show `node` as the user.

**9. Clean up**

```bash
docker rm -f test-node-api test-pg
docker network rm test-net
```

### Step 6

**1. Create a real credentials file — no more `1234`**

The repo's own README flags its example password as just that — an example. Put real ones in a file that never gets committed:

```bash
cd ~/multi-service-App
cat > db.env << 'EOF'
POSTGRES_USER=testuser
POSTGRES_PASSWORD=a-real-password-you-pick
POSTGRES_DB=testdb
EOF
echo "db.env" >> .gitignore
```

**2. Create the named volume**

```bash
docker volume create pgdata-test
```

Calling it `pgdata-test` deliberately — this is still the standalone proving-ground before Step 7's real Compose stack. We'll define the actual `pgdata` volume fresh there.

**3. Recreate the shared network**

```bash
docker network create test-net
```

**4. Run Postgres — with a healthcheck and resource limits this time**

Two things new here versus Steps 4/5's throwaway Postgres: a real `HEALTHCHECK` (so `depends_on: condition: service_healthy` will work once we're in Compose), and resource limits, both per the lab's locked-in decisions. Also note what's absent: no `-p 5432:5432`. Postgres never needs to be reachable from outside this Docker network — only the two APIs need it, and they'll reach it by container name.

```bash
docker run -d --name test-pg --network test-net \
  --env-file db.env \
  -v pgdata-test:/var/lib/postgresql/data \
  --memory=512m --cpus=1.0 \
  --health-cmd="pg_isready -U testuser -d testdb" \
  --health-interval=10s --health-timeout=3s --health-retries=3 --health-start-period=5s \
  postgres:16-alpine
```

Give it a few seconds, then confirm:

```bash
docker inspect --format '{{.State.Health.Status}}' test-pg
docker inspect --format '{{.Config.User}}' test-pg
```

Should show `healthy` and a non-root user (the official Postgres image already drops to the `postgres` user internally — nothing extra needed there).

A quick aside on `db/init.sql` from the repo: it exists for the case where the app's DB user is restricted and can't create tables itself — you'd run it once as an admin first. Our `testuser` owns `testdb` outright and each API already creates its own table on startup, so we don't need it here. Worth knowing it's there for later, though.

**5. Bring both APIs up against it**

Reusing the images you already built in Steps 4 and 5:

```bash
docker run -d --name test-python-api --network test-net -p 8001:8001 \
  -e DB_HOST=test-pg -e DB_PORT=5432 -e DB_NAME=testdb \
  -e DB_USER=testuser -e DB_PASSWORD=a-real-password-you-pick \
  -e DB_SSLMODE=disable -e DB_CONNECT_TIMEOUT=3 \
  python-api:0.1.0

docker run -d --name test-node-api --network test-net -p 8002:8002 \
  -e DB_HOST=test-pg -e DB_PORT=5432 -e DB_NAME=testdb \
  -e DB_USER=testuser -e DB_PASSWORD=a-real-password-you-pick \
  -e DB_SSL=false \
  node-api:0.1.0
```

**6. Watch the row counts climb**

```bash
curl -s http://localhost:8001/api/db | python3 -m json.tool | grep -i count
curl -s http://localhost:8002/api/db | python3 -m json.tool | grep -i count
```

Run that a couple of times, a few seconds apart — the counts should visibly increase (`HEARTBEAT_SECONDS` default is 10s). Note the numbers you see now; you'll compare against them in the next two steps.

**7. Prove persistence survives container removal**

```bash
docker rm -f test-pg

docker run -d --name test-pg --network test-net \
  --env-file db.env \
  -v pgdata-test:/var/lib/postgresql/data \
  --memory=512m --cpus=1.0 \
  --health-cmd="pg_isready -U testuser -d testdb" \
  --health-interval=10s --health-timeout=3s --health-retries=3 --health-start-period=5s \
  postgres:16-alpine
```

Wait for it to report healthy again, then re-check the row counts:

```bash
docker inspect --format '{{.State.Health.Status}}' test-pg
curl -s http://localhost:8001/api/db | python3 -m json.tool | grep -i count
curl -s http://localhost:8002/api/db | python3 -m json.tool | grep -i count
```

The counts should be higher than before, not reset — the container was destroyed and recreated from scratch, but the volume never moved. This is the proof: the data lives in the volume, not the container.

**8. Now break it on purpose — remove the volume too**

```bash
docker rm -f test-pg
docker volume rm pgdata-test
docker volume create pgdata-test

docker run -d --name test-pg --network test-net \
  --env-file db.env \
  -v pgdata-test:/var/lib/postgresql/data \
  --memory=512m --cpus=1.0 \
  --health-cmd="pg_isready -U testuser -d testdb" \
  --health-interval=10s --health-timeout=3s --health-retries=3 --health-start-period=5s \
  postgres:16-alpine
```

Wait for healthy, then check counts again:

```bash
curl -s http://localhost:8001/api/db | python3 -m json.tool | grep -i count
curl -s http://localhost:8002/api/db | python3 -m json.tool | grep -i count
```

Now they're back to near-zero — a fresh, empty database, because `docker volume rm` deleted the actual data directory. `docker rm` on a container is safe; `docker volume rm` is the genuinely destructive action. That distinction is the entire point of this step.

**9. Worth knowing before Step 7: the "password only applies to an empty volume" gotcha**

The repo's README calls this out directly, and it will bite you the first time you change `db.env` after the volume already has data: `POSTGRES_PASSWORD` (and `_USER`/`_DB`) are only read when Postgres initializes an empty data directory. Change the password in `db.env` and restart against an existing volume, and the old password silently remains — showing up as `password authentication failed`, not an obvious "ignored env var" error. Confirm with:

```bash
docker logs test-pg | head -20
```

Look for "Database directory appears to contain a database; Skipping initialization" — that's the tell. Fix it on the running database rather than nuking the volume:

```bash
docker exec -it test-pg psql -U testuser -d testdb -c "ALTER USER testuser WITH PASSWORD 'new-password-here';"
```

**10. Clean up**

```bash
docker rm -f test-python-api test-node-api test-pg
docker volume rm pgdata-test
docker network rm test-net
```

### Step 7 — Wiring It Together With Docker Compose + Custom Networks

**1. Create per-service `.env` files with real values**

The repo ships `.env` files created from `.env.example` templates (per its own quick-start), but those still point at defaults. Point them at the Compose-managed Postgres instead — using the container name, not an IP, since that's what Docker's embedded DNS will resolve on the shared network:

```bash
cd ~/multi-service-App

cat > api-python/.env << 'EOF'
DB_HOST=postgres-db
DB_PORT=5432
DB_NAME=testdb
DB_USER=testuser
DB_PASSWORD=a-real-password-you-pick
DB_SSLMODE=disable
DB_CONNECT_TIMEOUT=3
EOF

cat > api-node/.env << 'EOF'
DB_HOST=postgres-db
DB_PORT=5432
DB_NAME=testdb
DB_USER=testuser
DB_PASSWORD=a-real-password-you-pick
DB_SSL=false
EOF
```

Use the same password you put in `db.env` back in Step 6. Then make sure none of these get committed — the repo's default behavior is to commit `.env`, but yours now has a real password in it:

```bash
cat >> .gitignore << 'EOF'
api-python/.env
api-node/.env
EOF
```

**2. Write `docker-compose.yml` at the repo root**

```yaml
services:
  react-frontend:
    build:
      context: ./frontend
      args:
        VITE_PY_API: /api/py
        VITE_NODE_API: /api/node
    image: react-frontend:0.1.0
    container_name: react-frontend
    networks:
      - frontend-net
    mem_limit: 256m
    cpus: 0.5
    restart: unless-stopped

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

  node-api:
    build:
      context: ./api-node
    image: node-api:0.1.0
    container_name: node-api
    env_file:
      - api-node/.env
    networks:
      - backend-net
      - db-net
    depends_on:
      postgres-db:
        condition: service_healthy
    mem_limit: 256m
    cpus: 0.5
    restart: unless-stopped

  postgres-db:
    image: postgres:16-alpine
    container_name: postgres-db
    env_file:
      - db.env
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - db-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    mem_limit: 512m
    cpus: 1.0
    restart: unless-stopped

networks:
  frontend-net:
    driver: bridge
  backend-net:
    driver: bridge
  db-net:
    driver: bridge

volumes:
  pgdata:
```

A few things worth noticing:

- **No `ports:` anywhere.** Nothing is published to the host yet — not even for testing. That's intentional: only `edge-proxy` (Step 8) will ever publish a port, so we verify everything internally in this step, the same way the design intends it to work for real.
- `python-api` and `node-api` don't need their own `HEALTHCHECK` redefined here — Compose picks up the ones already baked into their Dockerfiles from Steps 4/5 automatically.
- `mem_limit`/`cpus` here are the plain Compose fields, not the `deploy: resources:` block — that's the Swarm-specific syntax you'll meet in Step 12 if you get to the stretch goal. Different syntax, same idea.

**3. Validate, then bring it up**

```bash
docker compose config    # catches YAML/syntax mistakes before anything runs
docker compose build
docker compose up -d
```

**4. Check status**

```bash
docker compose ps
```

You should see all four services `Up`, with `postgres-db`, `python-api`, and `node-api` reporting `(healthy)` within about 15–20 seconds. `react-frontend` won't show a health status — we didn't give it a `HEALTHCHECK`, which is fine for a static file server with nothing to check.

**5. Verify the segmentation — this is the actual point of the step**

Your Compose file created separate Docker networks, so only the APIs should be able to "see" the database:

```
python-api  -> connected to db-net
node-api    -> connected to db-net
postgres-db -> connected to db-net

react-frontend -> NOT connected to db-net
```

Both APIs should reach Postgres. This runs a Python command inside the `python-api` container:

```bash
docker compose exec python-api python -c "import socket; print(socket.gethostbyname('postgres-db'))"
```

This does the same test, but inside the `node-api` container:

```bash
docker compose exec node-api node -e "require('dns').lookup('postgres-db', (e,a) => console.log(e ? e.message : a))"
```

Both should print an IP address — DNS resolves because `python-api`/`node-api` and `postgres-db` share `db-net`. (Something like `172.21.0.2` is the internal Docker network IP of the `postgres-db` container on `db-net`, using Docker's private internal network.)

The frontend should not:

```bash
docker compose exec react-frontend wget -T 2 -qO- postgres-db:5432
```

Expect something like `wget: bad address 'postgres-db'` — not a timeout, a name resolution failure. That's a stronger proof than a blocked port: `react-frontend` isn't on `db-net` at all, so Docker's embedded DNS won't even tell it that name exists. This is the containerized version of Lab 01's subnet-scoped firewall check, and arguably cleaner — the isolation is structural, not just a rule that could be misconfigured.

**6. Confirm the apps are actually still working end-to-end**

```bash
docker compose exec python-api python -c "import urllib.request; print(urllib.request.urlopen('http://localhost:8001/api/db').read().decode())"
docker compose exec node-api node -e "require('http').get('http://localhost:8002/api/db', r => { let d=''; r.on('data', c => d+=c); r.on('end', () => console.log(d)); })"
```

Both should show `db_status connected` with heartbeat row counts climbing — same proof as Step 6, now running under Compose with no ports published at all.

**7. Check resource limits landed**

```bash
docker inspect --format '{{.HostConfig.Memory}} bytes, {{.HostConfig.NanoCpus}} nanocpus' postgres-db
```

Should reflect the 512MB / 1.0 CPU you set — confirming these aren't just decorative lines in the YAML.

### Step 8 — Reverse Proxy: Variant A (Path-Based Routing)

**1. Finally deal with Step 1 — this is the step where it actually matters**

We deferred this earlier because nothing was publishing a port yet. Now something is. Check before writing a single line of proxy config:

```bash
sudo systemctl status nginx
sudo ss -tulpn | grep ':80'
```

If nginx (or anything else) owns port 80:

```bash
sudo systemctl stop nginx
sudo systemctl disable nginx
sudo ss -tulpn | grep ':80'   # confirm empty output
```

**2. Create the proxy folder**

```bash
cd ~/multi-service-App
mkdir proxy
```

**3. Write the nginx config**

```bash
cat > proxy/nginx.pathbased.conf << 'EOF'
server {
    listen 8080;

    location /api/py/ {
        proxy_pass http://python-api:8001/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location /api/node/ {
        proxy_pass http://node-api:8002/;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }

    location / {
        proxy_pass http://react-frontend:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
    }
}
EOF
```

The trailing slash on both `location /api/py/` and `proxy_pass http://python-api:8001/` is load-bearing — that's what makes nginx strip the `/api/py` prefix before forwarding. So a browser request to `/api/py/api/db` arrives at `python-api` as just `/api/db` — matching the app's real endpoint, and matching the `VITE_PY_API=/api/py` build-time value from Step 3. Same logic for `/api/node/`.

**4. Write the Dockerfile**

Same non-root pattern as the frontend — nginx-unprivileged listening on 8080 internally, with Docker's port publishing doing the actual low-port binding at the host level, not the container.

```bash
cat > proxy/Dockerfile << 'EOF'
FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY nginx.pathbased.conf /etc/nginx/conf.d/default.conf
EXPOSE 8080

HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=3 \
  CMD wget -q --spider http://localhost:8080/ || exit 1
EOF
```

**5. Add `edge-proxy` to `docker-compose.yml`**

Add this service block, and the two extra networks it needs to bridge:

```yaml
  edge-proxy:
    build:
      context: ./proxy
    image: edge-proxy:0.1.0
    container_name: edge-proxy
    ports:
      - "80:8080"
    networks:
      - frontend-net
      - backend-net
    depends_on:
      - react-frontend
      - python-api
      - node-api
    mem_limit: 128m
    cpus: 0.5
    restart: unless-stopped
```

This is the only service in the whole file with a `ports:` entry — every other service stays internal-only, exactly as planned back in Step 7.

**6. Bring it up**

```bash
docker compose up -d --build
docker compose ps
```

`edge-proxy` should show `Up (healthy)` within a few seconds.

**7. Verify routing — from the Ubuntu host first**

```bash
curl -I http://localhost/
curl -s http://localhost/api/py/health
curl -s http://localhost/api/node/health
curl -s http://localhost/api/py/api/db | python3 -m json.tool
curl -s http://localhost/api/node/api/db | python3 -m json.tool
```

All four should respond correctly through port 80 — nothing here is talking to 8001/8002/8080 directly anymore, only to the proxy.

**8. Verify from the workstation — the real test**

Open `http://172.31.17.182/` in a browser. The React UI should load, and both status cards should now go green — because the frontend's baked-in `/api/py` and `/api/node` paths are same-origin relative to whatever address loaded the page, which is now the proxy. No CORS configuration needed anywhere, by design.

**9. Scope the firewall to the subnet**

Same principle as Lab 01 — allow the port only from `172.31.16.0/22`, not the world:

```bash
sudo ufw allow from 172.31.16.0/22 to any port 80 proto tcp
sudo ufw status
```

**10. Confirm non-root and healthy**

```bash
docker inspect --format '{{.Config.User}}' edge-proxy
docker inspect --format '{{.State.Health.Status}}' edge-proxy
```

### Step 9 — Secrets & Configuration Hygiene

You already have the baseline from Step 7 — real passwords live in `.env`/`db.env` files, and those are gitignored. That covers "don't commit secrets." This step goes one level further: even un-committed, a password sitting in `environment:`/`env_file:` is visible in `docker inspect`, in `docker compose config`, and to anyone who can read the container's process environment. Docker secrets close most of that.

**1. Create the secret, outside the compose file**

```bash
cd ~/multi-service-App
mkdir -p secrets
echo -n "a-real-password-you-pick" > secrets/db_password.txt

cat >> .gitignore << 'EOF'
secrets/
EOF
```

`echo -n` matters — no trailing newline, or some drivers will include it as part of the password.

**2. Commit `.env.example` templates instead of real `.env` files**

Satisfies the "at minimum, a committed example" half of the original decision — anyone cloning the repo sees the shape of the config without ever seeing a real credential:

```bash
cat > db.env.example << 'EOF'
POSTGRES_USER=testuser
POSTGRES_DB=testdb
EOF

cat > api-python/.env.example << 'EOF'
DB_HOST=postgres-db
DB_PORT=5432
DB_NAME=testdb
DB_USER=testuser
DB_SSLMODE=disable
DB_CONNECT_TIMEOUT=3
EOF

cat > api-node/.env.example << 'EOF'
DB_HOST=postgres-db
DB_PORT=5432
DB_NAME=testdb
DB_USER=testuser
DB_SSL=false
EOF
```

Notice `POSTGRES_PASSWORD` and `DB_PASSWORD` are gone from all three — real `.env`/`db.env` files, remove those two lines now too. The password's only home from here on is `secrets/db_password.txt`.

**3. Postgres: use the built-in `_FILE` convention — no code change needed**

The official Postgres image already knows how to read a password from a file instead of an env var — worth noticing, since your two API images don't have this built in and you'll build the equivalent by hand in the next step.

In `docker-compose.yml`, change the `postgres-db` service:

```yaml
  postgres-db:
    image: postgres:16-alpine
    container_name: postgres-db
    env_file:
      - db.env
    environment:
      POSTGRES_PASSWORD_FILE: /run/secrets/db_password
    secrets:
      - db_password
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - db-net
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U $$POSTGRES_USER -d $$POSTGRES_DB"]
      interval: 10s
      timeout: 3s
      retries: 3
      start_period: 5s
    mem_limit: 512m
    cpus: 1.0
    restart: unless-stopped
```

**4. Your two APIs: no such convention exists — build it yourself**

FastAPI and Express don't know what a Docker secret is; they just read `os.environ`/`process.env`. So the pattern is: mount the secret as a file, then have a tiny shell step read that file into an env var before the app starts. Edit the last line of `api-python/Dockerfile`:

```dockerfile
CMD ["sh", "-c", "export DB_PASSWORD=$(cat /run/secrets/db_password) && python main.py"]
```

And the last line of `api-node/Dockerfile`:

```dockerfile
CMD ["sh", "-c", "export DB_PASSWORD=$(cat /run/secrets/db_password) && node server.js"]
```

**5. Add the secret to both API services and the top-level `secrets:` block**

Add `secrets: - db_password` to `python-api` and `node-api` in `docker-compose.yml`, and add this at the bottom of the file, alongside `networks:` and `volumes:`:

```yaml
secrets:
  db_password:
    file: ./secrets/db_password.txt
```

**6. Rebuild (Dockerfiles changed) and bring it back up**

```bash
docker compose down
docker compose build python-api node-api
docker compose up -d
docker compose ps
```

Worth noting why this is safe without touching the volume: you're not changing the value of the password, only how it's delivered to each process. Postgres's data directory already has the old password baked in from Step 6's initialization — since the value is identical, everything still authenticates. If you'd changed the actual password here, you'd hit the exact "only read on an empty volume" gotcha from Step 6 again.

**7. Verify the secret is readable, without printing it anywhere**

```bash
docker compose exec node-api sh -c "test -r /run/secrets/db_password && wc -c < /run/secrets/db_password"
docker compose exec python-api sh -c "test -r /run/secrets/db_password && wc -c < /run/secrets/db_password"
```

A byte count confirms the file is there and readable, without ever putting the password itself in your terminal scrollback or shell history.

**8. Confirm the app still connects**

```bash
curl -s http://localhost/api/py/api/db | python3 -m json.tool | grep -i status
curl -s http://localhost/api/node/api/db | python3 -m json.tool | grep -i status
```

Both should still show `connected`.

**9. Confirm the password no longer shows up where it used to**

```bash
docker inspect --format '{{.Config.Env}}' node-api
docker compose config | grep -i password
```

The first command's output list should contain no `DB_PASSWORD` entry at all now — it only exists transiently inside the running shell process, never as a declared container config value. The second should print nothing.

**10. The honest caveat — say this out loud, don't skip it**

This isn't a complete solution, and it's worth knowing exactly what it does and doesn't protect against. It keeps the password out of the image, out of `docker inspect`, out of `docker compose config`, and out of git. It does not protect against someone with `docker exec` access to the running container — `docker compose exec node-api env | grep DB_PASSWORD` would still show it, because by the time the app is running, it genuinely needs the value in its own process environment to function. Real secret managers (Vault, AWS Secrets Manager, or Kubernetes `Secret` objects with RBAC) add access control on top of this same basic file-mount mechanism — which is exactly why this step is good practice to build the habit for, even in a lab where nobody but you has host access.

### Step 10 — Observability Basics

**1. Logs — the baseline you should already be reaching for**

```bash
docker compose logs -f                    # everything, live, interleaved
docker compose logs -f python-api         # just one service
docker compose logs --tail 50 node-api    # last 50 lines, no follow
docker compose logs --since 5m            # only the last 5 minutes
```

Watch `python-api` and `node-api` for a minute — you should see their heartbeat writes logging on the interval set by `HEARTBEAT_SECONDS`. That's your confirmation the apps are alive without having to `curl` anything.

**2. Log rotation — the thing everyone forgets until disk fills up**

By default, Docker's `json-file` log driver keeps growing forever. In a real deployment, an app that logs a lot can quietly fill the disk over weeks. Add a `logging:` block to every service in `docker-compose.yml` — here it is on `python-api`, repeat the same block on `node-api`, `postgres-db`, `react-frontend`, and `edge-proxy`:

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
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
```

Apply it:

```bash
docker compose up -d
```

Worth noticing: this only recreates the services whose config actually changed — Compose compares the new config against what's running and leaves untouched services alone. You'll see this in the output as `Recreating` for each service, but no interruption to ones you didn't just edit (there shouldn't be any here, since all five changed together).

Verify it landed:

```bash
docker inspect --format '{{json .HostConfig.LogConfig}}' python-api
```

You should see `"MaxSize":"10m","MaxFile":"3"` in the output — each container now caps at 30MB of retained logs total, rotated automatically.

**3. `docker stats` — watching the resource limits from Step 7 actually apply**

```bash
docker stats
```

A live, auto-refreshing table. Columns worth reading deliberately: `CPU %`, `MEM USAGE / LIMIT`, `NET I/O`, `BLOCK I/O`. Confirm the LIMIT column shows 256MiB for the APIs and 512MiB for Postgres — those aren't just numbers sitting in the YAML, they're actually enforced by the kernel via cgroups. Leave this running in its own terminal for the next part; `docker stats --no-stream` gives a single snapshot if you'd rather not.

**4. `docker events` — the live stream of what the daemon is doing**

Open a second terminal:

```bash
docker events
```

This streams container lifecycle events (start, stop, die, health_status, oom) as they happen, across every container on the host. Leave it running — you'll want it for the next step.

**5. Deliberately trigger a resource limit failure**

Talking about `mem_limit` is one thing; watching it actually kill a process is a much stronger lesson. Temporarily drop `node-api`'s limit absurdly low:

```yaml
  node-api:
    # ...
    mem_limit: 20m
```

```bash
docker compose up -d node-api
```

Watch your `docker events` terminal — within seconds you should see `oom` and `die` events for `node-api`. Then check what happened:

```bash
docker inspect --format '{{.State.OOMKilled}}' node-api
docker inspect --format '{{.RestartCount}}' node-api
docker compose ps
```

`OOMKilled` should show `true`, and because of `restart: unless-stopped` from Step 7, you'll likely see it crash-looping — restarting, hitting the same limit, dying again, `RestartCount` climbing. That loop is itself worth seeing: a resource limit that's genuinely too low doesn't fail gracefully, it fails repeatedly, forever, until someone fixes the config or the limit.

Revert immediately — don't let it loop for long:

```yaml
  node-api:
    # ...
    mem_limit: 256m
```

```bash
docker compose up -d node-api
docker compose ps
```

Confirm it settles back to `Up (healthy)` and `RestartCount` stops climbing.

**6. A live dashboard — cAdvisor**

`docker stats` is fine for a quick look; cAdvisor gives you the same data as a browsable, auto-refreshing dashboard per container. One honest caveat before adding it: cAdvisor needs broad, privileged host access to read cgroup/container metrics — a real tension with the "least privilege" thread running through this whole lab. That's an accepted, well-known trade-off for this specific tool (it's reading host-level resource accounting, not app data), but it's worth deciding deliberately rather than copy-pasting without noticing:

```yaml
  cadvisor:
    image: gcr.io/cadvisor/cadvisor:v0.49.1
    container_name: cadvisor
    privileged: true
    ports:
      - "8081:8080"
    volumes:
      - /:/rootfs:ro
      - /var/run:/var/run:ro
      - /sys:/sys:ro
      - /var/lib/docker/:/var/lib/docker:ro
      - /dev/disk/:/dev/disk:ro
    devices:
      - /dev/kmsg
    restart: unless-stopped
```

```bash
docker compose up -d cadvisor
```

Again — this only starts the one new service; your other five keep running undisturbed.

Scope it to the subnet, same as every other exposed port in this lab:

```bash
sudo ufw allow from 172.31.16.0/22 to any port 8081 proto tcp
```

From the workstation, browse to `http://172.31.17.182:8081` — you'll see live CPU/memory/network graphs per container, including the OOM spike you just caused on `node-api` if you're quick enough to catch it in the history.

**Verification checklist for this step**

- `docker compose logs` shows heartbeat activity from both APIs.
- `docker inspect ... LogConfig` confirms rotation (10m/3 files) on all five original services.
- `docker stats` shows enforced memory limits matching the YAML.
- You watched `node-api` get OOM-killed, confirmed `OOMKilled: true`, and reverted the limit.
- cAdvisor is reachable from the workstation on `:8081`, scoped to the subnet via ufw.

### Step 11 — Image Hygiene & Security Pass

**1. Install a scanner — Trivy**

Docker Scout is bundled with the CLI but its full CVE database needs `docker login` (Docker Hub account) to unlock past the basic view. Trivy is open source, works fully offline after its first vulnerability DB pull, and needs no account — better fit for a lab. Install it via its official apt repo:

```bash
sudo apt-get install -y wget apt-transport-https gnupg
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | sudo gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" | sudo tee -a /etc/apt/sources.list.d/trivy.list
sudo apt-get update
sudo apt-get install -y trivy
```

**2. Scan every image in the stack**

```bash
trivy image --severity CRITICAL,HIGH react-frontend:0.1.0
trivy image --severity CRITICAL,HIGH python-api:0.1.0
trivy image --severity CRITICAL,HIGH node-api:0.1.0
trivy image --severity CRITICAL,HIGH edge-proxy:0.1.0
trivy image --severity CRITICAL,HIGH postgres:16-alpine
```

Filtering to `CRITICAL,HIGH` is a deliberate choice, not laziness — a fresh scan of almost any real-world image turns up dozens of LOW/MEDIUM findings in transitive OS packages that may never even be exploitable in your usage. Triaging everything trains you to stop reading scanner output; triaging what actually matters is the habit worth building.

**3. How to read a finding**

Each row gives you a package, installed version, a CVE ID, severity, and — critically — a "Fixed Version" column. That last column is what turns a scan into an action:

- **Fixed version present** → a newer build of the same package/base image already resolves it. Usually means: bump the base image tag, rebuild, rescan.
- **Fixed version blank** → no patch exists yet. Nothing to do today except note it and rescan periodically — this is a real, common outcome, not a tool failure.

If any CRITICAL finding on your own three built images has a fixed version available, act on it now:

```bash
docker build --no-cache -t python-api:0.1.1 ./api-python
trivy image --severity CRITICAL,HIGH python-api:0.1.1
```

`--no-cache` matters here — otherwise Docker may reuse a cached layer from the exact same base image tag, and you won't actually pull the patched packages.

**4. Prove the multi-stage build discipline mattered — build the "naive" version and compare**

Talking about "multi-stage keeps images small" is easy to nod along to; seeing the actual number is what makes it stick. Build a deliberately naive single-stage version of `node-api` — one that skips everything Step 5 was careful about:

```bash
mkdir -p /tmp/naive-node-api
cp -r ~/multi-service-App/api-node/* /tmp/naive-node-api/

cat > /tmp/naive-node-api/Dockerfile << 'EOF'
FROM node:20
WORKDIR /app
COPY . .
RUN npm install
CMD ["node", "server.js"]
EOF

docker build -t node-api:naive /tmp/naive-node-api
```

Now compare, side by side:

```bash
docker images | grep node-api
```

Expect `node-api:naive` to land somewhere in the 900MB–1.2GB range, versus roughly 150–200MB for `node-api:0.1.0`. The gap comes from three stacked decisions, each worth naming explicitly: `node:20` (full Debian base, ~1GB) vs. `node:20-alpine` (~50MB); `npm install` (pulls devDependencies too) vs. `npm ci --omit=dev`; and a single stage that keeps the entire build toolchain in the final image vs. a multi-stage build that throws it away. Scan the naive one too, out of curiosity:

```bash
trivy image --severity CRITICAL,HIGH node-api:naive
```

You'll likely see a noticeably longer finding list — a bigger base image means a bigger OS package surface means more CVEs, independent of your own code. Clean it up once you've seen the comparison:

```bash
docker rmi node-api:naive
rm -rf /tmp/naive-node-api
```

**5. Confirm non-root across every service — the full check, all at once**

Individual steps checked this one service at a time; now verify the whole running stack together:

```bash
for c in react-frontend python-api node-api postgres-db edge-proxy; do
  echo -n "$c: "
  docker inspect --format '{{.Config.User}}' $c
done
```

Every line should show a non-empty, non-root value (`nginx`, `app`, `node`, `postgres`, `nginx` respectively — exact names depend on each base image's convention). An empty result means that container is running as root — worth tracking down and fixing before calling this step done, not after.

**6. Optional but cheap — lint the Dockerfiles themselves**

Trivy and the root check catch what's in the image; `hadolint` catches bad patterns in the Dockerfile that produced it — things like using `latest`, missing a package version pin, or running `apt-get update` and `install` in separate `RUN` layers (which silently breaks Docker's build cache in a way that can reintroduce stale packages later). One command, no install needed:

```bash
docker run --rm -i hadolint/hadolint < ~/multi-service-App/api-python/Dockerfile
docker run --rm -i hadolint/hadolint < ~/multi-service-App/api-node/Dockerfile
docker run --rm -i hadolint/hadolint < ~/multi-service-App/frontend/Dockerfile
docker run --rm -i hadolint/hadolint < ~/multi-service-App/proxy/Dockerfile
```

Any findings come back as a rule code (e.g. `DL3018`) plus a plain-English explanation — worth reading even for the ones you decide not to fix, since the explanation itself is the actual lesson.

**Verification checklist for this step**

- All five images scanned; any CRITICAL finding on your own images either has a documented "no fix yet" reason or has been rebuilt against a patched base.
- `node-api:naive` vs. `node-api:0.1.0` size comparison recorded — you've seen the multi-stage payoff as an actual number, not just a claim.
- Every one of the five running containers confirmed non-root in a single pass.
- Dockerfiles linted with hadolint; findings reviewed even if not all acted on.

### Step 12 (Stretch) — Preview of Orchestration & Real-LAN Networking

Two independent, both throwaway, both diagnostic rather than something we keep running. Let's do Swarm first, then macvlan.

#### Part A — Docker Swarm Preview

**1. Turn this host into a (single-node) swarm**

```bash
docker swarm init --advertise-addr 172.31.17.182
```

Output confirms Swarm initialized and shows a `docker swarm join` token — irrelevant here since we're not adding a second node, but that token is exactly what a real multi-host Lab 03 would use.

**2. Convert `docker-compose.yml` into a stack file**

This is the actual point of the exercise — the shape of the config that changes, not just the command. Three things Swarm needs that plain Compose doesn't:

- **No `build:`.** `docker stack deploy` never builds images — it only ever pulls a tagged image that must already exist. In a real multi-node swarm, that image needs to be in a registry every node can reach; on our single node, the local image Docker already has is enough. This is worth sitting with for a second: it's the exact moment a lab habit ("just build inline") stops working in production, where CI builds and pushes an image before anything gets deployed.
- **`deploy:` block instead of top-level `mem_limit`/`cpus`/`restart`.** Different key, same intent.
- **Overlay networks instead of bridge.** This is the network driver primer's last row showing up for real — bridge is node-local by design, and Swarm's routing mesh (the thing that lets a published port work no matter which node a task landed on) is built on overlay. On a one-node swarm this distinction can't actually bite you yet, but the config still has to speak Swarm's language.

```bash
cd ~/multi-service-App
cat > docker-stack.yml << 'EOF'
services:
  react-frontend:
    image: react-frontend:0.1.0
    networks:
      - frontend-net
    deploy:
      resources:
        limits:
          memory: 256M
      restart_policy:
        condition: on-failure

  python-api:
    image: python-api:0.1.0
    env_file:
      - api-python/.env
    networks:
      - backend-net
      - db-net
    deploy:
      resources:
        limits:
          memory: 256M
      restart_policy:
        condition: on-failure

  node-api:
    image: node-api:0.1.0
    env_file:
      - api-node/.env
    networks:
      - backend-net
      - db-net
    deploy:
      resources:
        limits:
          memory: 256M
      restart_policy:
        condition: on-failure

  postgres-db:
    image: postgres:16-alpine
    env_file:
      - db.env
    volumes:
      - pgdata:/var/lib/postgresql/data
    networks:
      - db-net
    deploy:
      resources:
        limits:
          memory: 512M
      restart_policy:
        condition: on-failure

  edge-proxy:
    image: edge-proxy:0.1.0
    ports:
      - "80:8080"
    networks:
      - frontend-net
      - backend-net
    deploy:
      resources:
        limits:
          memory: 128M
      restart_policy:
        condition: on-failure

networks:
  frontend-net:
    driver: overlay
  backend-net:
    driver: overlay
  db-net:
    driver: overlay

volumes:
  pgdata:
EOF
```

Notice `depends_on` and healthcheck conditions are gone too — Swarm doesn't support `condition: service_healthy` gating at deploy time the way Compose does. In practice this means Postgres might not be ready the instant `python-api`/`node-api` start; the `restart_policy: on-failure` is Swarm's answer — a task that crashes because the DB isn't up yet gets retried automatically until it succeeds. Different mechanism, same underlying problem to solve.

**3. Stop the Compose stack first — avoid a port-80 collision with the new one**

```bash
docker compose down
```

**4. Deploy the stack**

```bash
docker stack deploy -c docker-stack.yml labstack
```

**5. Inspect it — the vocabulary shifts here too**

```bash
docker stack services labstack
docker stack ps labstack
docker service logs labstack_python-api
```

`docker service ps` is doing the job `docker compose ps` did — but notice the container names now look like `labstack_edge-proxy.1.<random-id>` instead of the fixed `edge-proxy` from Compose. That's Swarm treating each running instance as a disposable task, not a named thing you address directly — another small seam pointing toward Kubernetes pods, which work the same way.

**6. Verify it's still the same app**

```bash
curl -I http://localhost/
```

From the workstation: `http://172.31.17.182/` should load exactly as before — the routing mesh published port 80 the same way `docker compose`'s port mapping did, just through a different mechanism underneath.

**7. Try the thing Compose made easy and Swarm doesn't**

```bash
# edit api-node/server.js, change something trivial
docker build -t node-api:0.1.0 ./api-node
docker service update --image node-api:0.1.0 labstack_node-api
```

`docker service update` is Swarm's rolling-update mechanism — it replaces the running task with a new one using the freshly tagged image, one task at a time (irrelevant with `replicas: 1`, but this is exactly the command that matters once you scale up). There's no `docker stack deploy --build` shortcut; the image always has to already exist, tagged, before Swarm will touch it.

**8. Tear it down, leave swarm mode, go back to the normal setup**

```bash
docker stack rm labstack
docker swarm leave --force
docker compose up -d
docker compose ps
```

Confirm all five original services are back up before moving on.

#### Part B — Macvlan: Giving a Container a Real LAN Identity

Fair warning before starting: this depends on the hypervisor allowing promiscuous mode / MAC spoofing on this VM's virtual NIC — a setting you may not control. If it fails, that's a legitimate result, not a mistake — note it and move on.

**1. Find the host's real network interface**

```bash
ip addr
```

Look for the interface carrying `172.31.17.182` (commonly `ens160`, `ens192`, or `eth0` depending on the hypervisor) — you'll need its exact name below.

**2. Pick an IP that's definitely not in use**

Anything already reachable is a real conflict on a real subnet, not a Docker sandbox. Pick something toward the top of the range and confirm it's silent first:

```bash
ping -c 2 172.31.19.250
```

No reply = safe to claim. (If you're not the sole admin of `172.31.16.0/22`, worth a quick check with whoever manages it before claiming an IP permanently.)

**3. Create the macvlan network**

```bash
docker network create -d macvlan \
  --subnet=172.31.16.0/22 \
  --gateway=172.31.16.1 \
  -o parent=<your-interface-name> \
  lan-macvlan
```

**4. Run a container directly on the LAN**

```bash
docker run -d --name macvlan-test --network lan-macvlan --ip=172.31.19.250 nginx:alpine
```

**5. Test from the workstation — not from the Ubuntu host**

```bash
curl -I http://172.31.19.250
```

This should work with no port mapping at all — the container has its own MAC and IP directly on the wire, indistinguishable from another physical host. This is the direct contrast to everything else in this lab: every other service reached the network through the host's IP plus a published port; this one bypasses that entirely.

**6. The genuinely interesting quirk — try this from the Ubuntu host itself**

```bash
curl -I http://172.31.19.250
```

Run on the host, this very often fails — most Linux kernels block a macvlan parent interface from talking directly to its own macvlan children by default. It's not a misconfiguration; it's how the driver works. If you need host-to-container reachability on a macvlan setup, the usual fix is adding a macvlan subinterface on the host itself — worth knowing this exists, not necessary to build today.

**7. If it didn't work at all**

Errors like `RTNETLINK answers: Operation not permitted` when the container starts, or ARP simply going nowhere and the workstation `curl` timing out, point at the hypervisor blocking promiscuous mode on the vNIC — a setting on the vSwitch/port group, not in Docker. Confirming that's the failure mode is still a valid outcome for this exercise.

**8. Clean up**

```bash
docker rm -f macvlan-test
docker network rm lan-macvlan
```

---

## Documented Issues

### For Step 5

That error pattern (empty response, unhealthy) means the app never came up and started listening — not a DB or network issue, since the `node` user is correct and the container process itself is the problem. Let's see why before touching Compose.

Run these and check the output:

```bash
docker ps -a --filter name=test-node-api
docker logs test-node-api --tail 50
```

And check what the app's actual entry point is — the Dockerfile used `CMD ["node", "index.js"]` as a guess, and if the real file is `server.js` or `app.js`, that alone would cause exactly this symptom (container exits immediately, nothing ever binds to 8002, `curl` gets nothing, healthcheck never passes).
