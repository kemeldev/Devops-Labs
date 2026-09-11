# Lab 02 — Dockerizing a Multi-Service App: React + Python API + Node.js API + PostgreSQL, Behind a Reverse Proxy.

## Objective
Carry the routing/traffic concepts from Lab 01 into containers, and use them as the vehicle to build real Docker fluency:

1. Containerize the React/Vite frontend from `kemeldev/multi-service-App`.
2. Containerize the Python API (FastAPI) from the same repo.
3. Containerize the Node.js API (Express) from the same repo.
4. Run PostgreSQL as a container with real, durable persistence.
5. Put a reverse proxy / load balancer container in front of everything, with the same two routing variants explored in Lab 01 (round-robin and path-based) — now expressed as Docker networks, service discovery, and `upstream`/`location` blocks instead of VM IPs.

Non-production lab, same philosophy as Lab 01: build it with real-world habits (least-privilege networking, non-root containers, pinned/minimal images, secrets hygiene) so they carry forward.

**Decision locked in this revision — single host.** Unlike Lab 01, every container in this lab runs on **one** Docker host rather than being spread across three VMs. Splitting containers back across multiple machines would just reintroduce the distro-specific complexity Docker is designed to remove, without teaching anything new about Docker itself. The reverse proxy is **not** a separate machine — it's just another container on the same host, on the same networks, which is also the idiomatic pattern (and the direct precursor to a Kubernetes Ingress controller later).

**Long-term direction (not part of this lab):** this compose stack is deliberately structured so it can be translated almost 1:1 into Kubernetes manifests afterward — service names → Services, networks → NetworkPolicies, healthchecks → readiness/liveness probes, resource limits → requests/limits, `.env`/secrets → ConfigMaps/Secrets. Multi-*host* Docker (Swarm overlay networks) is deliberately deferred to a future Lab 03 — see Step 12.

## Environment

| Role | Hostname | IP | OS | Software |
|---|---|---|---|---|
| Docker host (all 5 containers) | `ubuntuserver1.ssa.veeam.local` | 172.31.17.182 | Ubuntu Server | Docker Engine + Compose plugin |
| Control point | Windows workstation | 172.24.209.0/24 | Windows | SSH client + browser |

This reuses the Ubuntu VM from Lab 01 — it already has Docker's usual dependencies satisfied and, per the repo's own README, was previously used as the reachable host for this exact app's database (`DB_HOST=ubuntuserver1.ssa.veeam.local`). The Fedora and RHEL VMs from Lab 01 are **not used** in this lab; they're earmarked for a future multi-host (Swarm) or Kubernetes lab.

**Scope of "reachable from anywhere":** same as Lab 01 — reachable from anywhere on `172.31.16.0/22`, not the public internet. Only the reverse proxy container publishes a port to the host; `ufw` on Ubuntu scopes that port to the /22, exactly as it scoped port 80 in Lab 01 Step 2.

## The app (`kemeldev/multi-service-App`)

Repo: <https://github.com/kemeldev/multi-service-App> — a 3-tier test app built specifically for exercising ports, connectivity, CORS, and DB reachability. Structure:

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
| frontend | 5173 (dev) | — | Vite dev server only — for the container we build static and serve via nginx, per Lab 01's "static builds only" rule |
| api-python | 8001 | `/`, `/health`, `/api/info`, `/api/db`, `/docs` | FastAPI, writes to `py_heartbeat` table every `HEARTBEAT_SECONDS` |
| api-node | 8002 | `/`, `/health`, `/api/info`, `/api/db` | Express, writes to `node_heartbeat` table |
| postgres | 5432 | — | `testuser` / `testdb`, both APIs share the instance but never the table |

Two details from the repo that directly shape the Docker build:

- **`/health` already exists and never touches the DB** — exactly what a container `HEALTHCHECK` wants. No need to add one.
- **The frontend reads `VITE_PY_API` / `VITE_NODE_API` at *build time*, not runtime.** This is a classic React/Vite-in-Docker gotcha: once `npm run build` runs, those URLs are baked into the static JS bundle — an env var set on `docker run` after the fact does nothing. For this lab, build the frontend image with `VITE_PY_API=/api/py` and `VITE_NODE_API=/api/node` (relative paths), so the browser always calls back through the proxy's own origin. That sidesteps CORS entirely and avoids baking a container IP into the bundle. This is worth calling out explicitly in Step 3 — it's the kind of thing that "works on my machine" and then silently breaks the moment the app moves host.

## Networking

| Network | Driver | Members |
|---|---|---|
| `frontend-net` | user-defined bridge | `edge-proxy`, `react-frontend` |
| `backend-net` | user-defined bridge | `edge-proxy`, `python-api`, `node-api` |
| `db-net` | user-defined bridge | `python-api`, `node-api`, `postgres-db` |

Only `edge-proxy` publishes a port to the host. Everything else is reachable only via container-name DNS on the networks above — the containerized analog of scoping Lab 01's firewall rules to `172.31.16.0/22` instead of `0.0.0.0/0`. (Diagram provided separately in chat.)

### Docker network driver primer — what we use, and why we skip the rest

You listed all eight drivers Docker exposes. Most are genuinely the wrong tool for a single-host lab — here's the reasoning, not just the verdict:

| Driver | What it is | In this lab? |
|---|---|---|
| **Bridge (default)** | Docker's built-in single-host NAT network. Every container lands here unless told otherwise; everything can reach everything, no DNS by container name. | Used only for a 2-minute contrast demo in Step 2 — this is *why* we don't use it for real. |
| **User-defined bridge** | Same driver, but a network you name yourself. Containers on it get real DNS-by-name and only see what they're explicitly attached to. | ✅ **Primary driver for the whole lab** — the three networks above. |
| **Host** | Container shares the host's network namespace directly — no isolation, no port mapping. | Brief demo only, in Step 2, to *feel* why it's risky (it's also exactly what caused the nginx-port-80 collision flagged in Step 1). |
| **None** | No networking at all. | Brief demo in Step 2 — a one-off maintenance/backup container that has no business talking to the network. |
| **Macvlan (bridge mode)** | Container gets a real, routable MAC + IP directly on the physical LAN — indistinguishable from another physical host on the wire. | **Optional stretch (Step 12)** — genuinely interesting here because it would give a container a real `172.31.16.0/22` address, mirroring how Lab 01's VMs got real subnet IPs. Flag: needs the hypervisor's virtual NIC to allow promiscuous mode / MAC spoofing, which not all hypervisors permit for a VM's vNIC — treat as "try it, fall back to conceptual" rather than a guaranteed win. |
| **Macvlan (802.1q trunk)** | Same idea, one physical NIC split into per-VLAN subinterfaces. | Conceptual only — needs a VLAN-tagged switchport we don't have in this lab. |
| **IPvlan L2/L3** | Similar outcome to macvlan (containers get real LAN IPs) but they share the host's MAC address, which plays nicer with switches that block MAC spoofing. | Conceptual only — same real-LAN-IP idea as macvlan without the promiscuous-mode requirement; worth knowing exists as the fallback when macvlan is blocked. |
| **Overlay** | A virtual network spanning *multiple* Docker hosts, used by Swarm/Kubernetes so containers on different physical machines can talk as if on one network. | Not this lab — it's the natural next thing to learn once you add a second host (Step 12 stretch / future Lab 03). |

The takeaway to internalize: **user-defined bridge is the correct default for anything single-host**, host/none are useful mainly as contrast so you *recognize* when something is wrong, and macvlan/ipvlan/overlay only start earning their complexity once containers need a real routable identity on the physical network or need to span more than one host.

## Decisions locked in for this lab

- **Multi-stage builds everywhere.** Every image has a build stage and a slim runtime stage; no compilers, dev dependencies, or source maps ship in the final image.
- **Non-root containers.** Every service runs as a non-root `USER` (Node and Nginx images already provide one — use it; add one explicitly for the Python image).
- **`.dockerignore` per service** (`node_modules`, `.git`, `.env`, `dist`, `__pycache__`, etc.) — nothing bloats the build context or leaks into an image by accident.
- **Config via environment variables**, loaded through `.env` files and `docker compose`, never hardcoded. A `.env.example` is committed; the real `.env` is gitignored. The repo's example Postgres password (`1234`) gets replaced before this ever runs anywhere shared.
- **Frontend API URLs baked at build time as relative paths** (`/api/py`, `/api/node`) — see the callout above. This is a deliberate, documented exception to "config via env vars," because Vite's build-time behavior makes a true runtime env var impossible without an extra templating step (out of scope for this lab, worth a footnote if you want to go further later).
- **Named volume for Postgres** (`pgdata`) so data survives container recreation. Removing the *container* must not remove the *data* — removing the *volume* is a separate, deliberate action.
- **Custom user-defined bridge networks, not the default bridge network** — see the primer above.
- **Healthchecks on every service**, using the app's existing `/health` endpoints for the two APIs, so `depends_on` can wait for "actually ready," not just "process started."
- **Resource limits (`cpus`, `mem_limit`) set from day one**, even in a lab — "it only works because nothing is constrained" is a habit we don't want carrying into Kubernetes.
- **Pinned, minimal base images** — `alpine`/`slim` variants, explicit version tags, never `:latest`.
- **Naming/tagging convention agreed up front** (`<yourname>/react-frontend:0.1.0`, etc.) so pushing to a registry later is a non-event.
- **TLS, secrets vaulting, and multi-host orchestration (Swarm/K8s) deferred** — same "deferred, not ignored" posture TLS had in Lab 01.

## Planned Steps

### Step 0 — Prep & Docker fundamentals refresher
- Install Docker Engine + Compose plugin; confirm with `docker run hello-world`.
- Deliberately review the vocabulary shift from Lab 01: **image vs. container vs. volume vs. network** — this is the main conceptual leap from a bare-metal VM mental model.

### Step 1 — Clear the decks on the Ubuntu host
This host ran nginx directly on port 80 in Lab 01 Step 2. Before any container tries to publish port 80, confirm nothing on the host already owns it:

```
sudo systemctl status nginx
sudo ss -tulpn | grep ':80\|:443'
```

If nginx (or anything else) is bound to 80/443:

```
sudo systemctl stop nginx
sudo systemctl disable nginx
sudo ss -tulpn | grep ':80\|:443'   # confirm empty output
```

Doing this explicitly, as its own step, avoids losing an hour later to "why won't my proxy container bind to port 80" — a genuinely common first-timer Docker networking trap that's really a host-port conflict in disguise.

### Step 2 — Docker network driver walkthrough (hands-on, throwaway containers)
Before building the real stack, feel the difference between drivers using disposable containers — delete everything from this step once done:

- **Default bridge:** `docker run -d --name t1 nginx:alpine` and `docker run -it --rm alpine ping t1` — observe that ping-by-name *fails* on the default bridge (no automatic DNS).
- **User-defined bridge:** `docker network create demo-net`, run two containers with `--network demo-net`, ping by name — observe it *works*. This is the "aha" that motivates using custom networks for real, going forward.
- **Host:** `docker run -d --network host --name t2 nginx:alpine` — try to also bind port 80 elsewhere and observe the collision; `docker rm -f t2` immediately after.
- **None:** `docker run -it --rm --network none alpine ping 8.8.8.8` — observe it can't reach anything, by design; this is the correct driver for a container that should never touch the network (e.g. a one-off backup/compression job reading a mounted volume).
- Clean up: `docker rm -f t1; docker network rm demo-net`.

### Step 3 — Containerize the React frontend
- Multi-stage `Dockerfile`: stage 1 (`node:20-alpine`) runs `npm ci && npm run build` with build args `VITE_PY_API=/api/py` and `VITE_NODE_API=/api/node`; stage 2 (`nginx:alpine`) copies `dist/` into `/usr/share/nginx/html`.
- **Call out the build-time-vs-runtime env var gotcha explicitly here** — it's the single most likely thing to trip this step up.
- Build and run standalone (`docker run -p 8080:80 ...`) before touching Compose, so failures are isolated to this one image.

### Step 4 — Containerize the Python API (FastAPI, :8001)
- Multi-stage build: install dependencies from `requirements.txt` in a builder stage, copy only the installed packages/venv into a slim `python:3.12-slim` runtime stage.
- `HEALTHCHECK` against the existing `/health` endpoint — no new code needed.
- Read the DB connection info only from environment variables (`DB_HOST`, `DB_PORT`, `DB_NAME`, `DB_USER`, `DB_PASSWORD`), matching the repo's existing `.env` pattern; test it standalone against a throwaway Postgres container before wiring up Compose.

### Step 5 — Containerize the Node.js API (Express, :8002)
- Same discipline: multi-stage build, `npm ci --omit=dev` in the runtime stage, use the `node` user the base image already provides.
- `HEALTHCHECK` against the existing `/health` endpoint.
- Same environment-variable-only rule for DB connection info (`DB_SSL=false` for this container, per the repo's README).

### Step 6 — PostgreSQL with real persistence
- `postgres:16-alpine` + named volume (`pgdata`) mounted at `/var/lib/postgresql/data`.
- Reuse `db/init.sql` from the repo (mounted into `docker-entrypoint-initdb.d/`) to create `testdb`/`testuser` and the two heartbeat tables on first boot — **with a real password from your own `.env`, not the repo's example `1234`.**
- **Prove persistence deliberately:** `docker compose down` (no `-v`) → bring it back up → `py_heartbeat`/`node_heartbeat` row counts keep climbing from where they left off. Then `docker compose down -v` → counts reset to zero. Breaking it on purpose is the lesson.

### Step 7 — Wire it together with Docker Compose + custom networks
- One `docker-compose.yml`, five services, the three networks defined above.
- `depends_on` with `condition: service_healthy` so the APIs wait for Postgres to be *ready*, not just *started*.
- Verify the segmentation from inside the containers: `react-frontend` cannot reach `postgres-db`; both APIs can. This is the containerized version of the subnet-scoped firewall exercise from Lab 01.

### Step 8 — Reverse proxy: two variants (mirrors Lab 01 Step 3)
- **Variant A — Path-based routing** (the realistic case for this app): `/` → `react-frontend`, `/api/py/` → `python-api`, `/api/node/` → `node-api`.
- **Variant B — Load-balanced replicas:** `docker compose up --scale node-api=3` and let an `upstream` block round-robin across replicas. This surfaces a real lesson Lab 01 only hinted at: with more than one instance, the API needs to be stateless, or requests start behaving inconsistently. (This app's heartbeat-per-table design makes that very visible — watch which replica's logs increment.)
- Keep both nginx configs side by side (`nginx.pathbased.conf`, `nginx.roundrobin.conf`) for reference, same as the two vhosts kept in Lab 01.

### Step 9 — Secrets & configuration hygiene
- Move the DB password out of a committed `.env` and into Docker Compose secrets (or, at minimum, `.env` + `.gitignore` + a committed `.env.example`, replacing the repo's plaintext example password).
- Discuss explicitly why this step foreshadows Kubernetes `Secret` objects later.

### Step 10 — Observability basics
- `docker compose logs -f`, and watch each API's own heartbeat logging.
- `docker stats` to watch the resource limits from "Decisions locked in" actually bite.
- Stretch: a lightweight cAdvisor/Prometheus/Grafana stack.

### Step 11 — Image hygiene & security pass
- Run `docker scout cves` (or `trivy image`) against all five images.
- Compare image sizes before/after the multi-stage builds — usually a dramatic before/after.
- Confirm no container runs as root: `docker inspect --format '{{.Config.User}}' <container>`.

### Step 12 (stretch) — Preview of orchestration and real-LAN networking
- Try `docker stack deploy` against the same Compose file in Swarm mode, just to feel the seam between Compose and an orchestrator — since, like Lab 01, the real long-term direction is Kubernetes next.
- Optional macvlan experiment: attach `edge-proxy` to a macvlan network carved out of `172.31.16.0/22`, so it gets a real routable IP on the subnet instead of a host-published port — directly comparable to how the Lab 01 VMs got real IPs. Good candidate for its own short write-up comparing NAT (bridge + published port) vs. L2 attachment (macvlan).

## Verification checklist
- [ ] `systemctl status nginx` confirms nginx is stopped/disabled on the Ubuntu host before the proxy container starts.
- [ ] All five images build with no warnings, on pinned base image versions.
- [ ] `docker inspect` confirms every container runs as non-root.
- [ ] `react-frontend` cannot resolve/reach `postgres-db`; both APIs can.
- [ ] `docker compose down -v` resets both heartbeat table row counts to zero; `down` (no `-v`) then `up` preserves them.
- [ ] Variant A: hitting `edge-proxy` on `/`, `/api/py/...`, `/api/node/...` routes to the correct backend and the React UI's status cards go green.
- [ ] Variant B: scaling `node-api` to 3 replicas shows round-robin behavior across them.
- [ ] No secret values appear in `docker inspect`, image layers, or git history.
