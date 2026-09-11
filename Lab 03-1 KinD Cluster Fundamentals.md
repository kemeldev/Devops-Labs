# Lab 3.1 — KinD Cluster Fundamentals & Core Object Literacy

## Objective
Get comfortable with the raw mechanics of a Kubernetes cluster — Nodes, Pods, Deployments, Services, Namespaces — using small, disposable objects with no connection to the real app yet. Nothing built in this sub-lab survives into Sub-lab 3.2; the goal is muscle memory and a correct mental model, not a deliverable.

This matters more here than it did in Lab 02: Docker Compose has one kind of object underneath everything (a container). Kubernetes has several, and they interact — a Deployment manages Pods, a Service routes to Pods by label, and getting the relationship between them intuitive now is what makes every later sub-lab easier to debug.

## Environment

| Role | Hostname | IP | OS | Software |
|---|---|---|---|---|
| KinD host | `ubuntuserver1.ssa.veeam.local` | 172.31.17.182 | Ubuntu Server | Docker Engine (Lab 02) + `kubectl` + `kind` |
| Control point | Windows workstation | 172.24.209.0/24 | Windows | SSH client + browser |

Before starting: stop Lab 02's Compose stack (`docker compose down`, from `~/multi-service-App`) to free up resources for the KinD cluster's node-containers.

## Decisions locked in for this sub-lab

- **Cluster topology: 1 control-plane + 2 workers**, defined via an explicit KinD config file rather than the zero-config default — the point is to see the anatomy of a cluster, not just get one running.
- **Imperative commands first, deliberately** (`kubectl run`, `kubectl expose`) — not because they're the "right" way to work day to day, but because typing the raw command that creates a Pod, and then a separate one that creates a Service, makes the boundary between the two objects concrete before YAML abstracts it.
- **Everything in this sub-lab gets deleted before moving on** — same discipline as Lab 02's network-driver walkthrough. If an object from this sub-lab is still running when Sub-lab 3.2 starts, something was skipped.
- **The `multi-service-app` namespace gets created here**, even though nothing real lives in it yet — establishing the habit before there's real content to organize is the point.
- **Ingress port mappings and node label configured at cluster-creation time**, even though nothing uses them until Sub-lab 3.3 — a one-shot decision that can't be added later without recreating the cluster.

## Planned Steps

### Step 1 — Install `kubectl` and `kind`
Get both CLI tools onto the Ubuntu host and confirm they run. `kubectl` talks to a cluster (any cluster); `kind` is only responsible for creating/deleting the special local cluster made of Docker containers — worth being clear on that split from the start, since it's a common early confusion (people expect `kind` to also manage workloads inside the cluster; it doesn't, `kubectl` does that regardless of where the cluster runs).

### Step 2 — Write a KinD cluster config and create the cluster
Define a config file describing 1 control-plane node and 2 worker nodes, then create the cluster from it. This is the point where "a Kubernetes cluster" stops being an abstract phrase and becomes something you can point at: `docker ps` afterward will show the cluster's nodes as ordinary Docker containers, on the same Docker Engine as Lab 02's app containers.

One detail worth getting right now, even though it isn't used until Sub-lab 3.3: the control-plane node needs `extraPortMappings` for ports 80/443 (host port → container port) plus an `ingress-ready=true` node label, so an Ingress controller added later can actually be reached from the workstation. This only takes effect at cluster **creation** time — adding it afterward means deleting and recreating the cluster, and rebuilding everything from Sub-lab 3.2 on top of it again. Include it in the config file now rather than discovering the gap two sub-labs from now.

### Step 3 — Orient: tour the cluster before creating anything
Before building anything, look at what's already there. Every KinD cluster boots with a set of system components running as Pods in the `kube-system` namespace — CoreDNS (cluster-internal DNS) and `kube-proxy` (the component that actually implements Service load-balancing) chief among them. Seeing these running, by name, before they matter to you in Sub-lab 3.4, is worth the five minutes — it turns "kube-proxy makes Services load-balance" from something you're told into something you can point at.

### Step 4 — Imperative toy example: Pod → Service → reach it
Create a single throwaway Pod running a simple web server image, directly with an imperative command (no YAML yet). Then create a Service exposing it, also imperatively. Then reach it from the workstation — first via `kubectl port-forward` (a direct tunnel to one specific Pod, useful for debugging, not a real access pattern) to build intuition for the difference between "a Pod exists" and "something can reach it."

### Step 5 — Declarative rebuild, and the self-healing comparison
Delete the imperative objects, then recreate the same thing as YAML manifests — first a bare Pod, then a Deployment, then a Service — applying each with `kubectl apply -f`. Once the Deployment version is running, deliberately delete its Pod directly (not the Deployment) and watch what happens: a new Pod appears automatically, because the Deployment's whole job is enforcing "N replicas of this Pod should exist" as a standing intent, not a one-time action. Repeat the same deletion against the bare Pod from earlier (recreate it first) — nothing replaces it. This contrast is the single most important concept in this sub-lab: a Pod is a fact, a Deployment is a promise.

### Step 6 — Create the `multi-service-app` namespace
Create the namespace that all real work will live in from Sub-lab 3.2 onward, and set it as the default for your current `kubectl` context so you stop needing `-n multi-service-app` on every command. Confirm the toy objects from Steps 4–5 are still sitting in `default`, untouched — a concrete demonstration of what namespace isolation actually does.

### Step 7 — Clean up everything from this sub-lab
Delete every toy Pod, Deployment, and Service created above. Confirm `default` is empty and only `kube-system`'s components remain, alongside the new (still-empty) `multi-service-app` namespace.

## Verification checklist
- [ ] `kubectl get nodes` shows 3 nodes (1 control-plane, 2 workers), all `Ready`.
- [ ] Cluster config included `extraPortMappings` for 80/443 and the `ingress-ready=true` label on the control-plane node — confirmed before creating, since it can't be added afterward without recreating.
- [ ] `kubectl get pods -n kube-system` shows CoreDNS and `kube-proxy` Pods running, and you can explain in one sentence what each does.
- [ ] The imperative Pod + Service were reachable via `port-forward` before being deleted.
- [ ] Deleting a Deployment-managed Pod triggered automatic recreation; deleting a bare Pod did not.
- [ ] `multi-service-app` namespace exists and is set as your current context's default.
- [ ] `kubectl get all -n default` and `kubectl get all -n multi-service-app` both come back empty — nothing left over.
