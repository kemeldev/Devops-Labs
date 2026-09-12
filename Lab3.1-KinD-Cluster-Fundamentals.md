# Lab 3.1 — KinD Cluster Fundamentals & Core Object Literacy

## Objective

Get comfortable with the raw mechanics of a Kubernetes cluster — Nodes, Pods, Deployments, Services, Namespaces — using small, disposable objects with no connection to the real app yet. Nothing built in this sub-lab survives into Sub-lab 3.2; the goal is muscle memory and a correct mental model, not a deliverable.

This matters more here than it did in Lab 02: Docker Compose has one kind of object underneath everything (a container). Kubernetes has several, and they interact — a Deployment manages Pods, a Service routes to Pods by label, and getting the relationship between them intuitive now is what makes every later sub-lab easier to debug.

## Environment

| Role | Hostname | IP | OS | Software |
|---|---|---|---|---|
| KinD host | `ubuntuserver1.ssa.veeam.local` | 172.31.17.54 | Ubuntu Server | Docker Engine (Lab 02) + kubectl + kind |
| Control point | Windows workstation | 172.24.209.0/24 | Windows | SSH client + browser |

Before starting: stop Lab 02's Compose stack (`docker compose down`, from `~/multi-service-App`) to free up resources for the KinD cluster's node-containers.

## Decisions Locked In For This Sub-Lab

- **Cluster topology: 1 control-plane + 2 workers**, defined via an explicit KinD config file rather than the zero-config default — the point is to see the anatomy of a cluster, not just get one running.
- **Imperative commands first, deliberately** (`kubectl run`, `kubectl expose`) — not because they're the "right" way to work day to day, but because typing the raw command that creates a Pod, and then a separate one that creates a Service, makes the boundary between the two objects concrete before YAML abstracts it.
- **Everything in this sub-lab gets deleted before moving on** — same discipline as Lab 02's network-driver walkthrough. If an object from this sub-lab is still running when Sub-lab 3.2 starts, something was skipped.
- **The `multi-service-app` namespace gets created here**, even though nothing real lives in it yet — establishing the habit before there's real content to organize is the point.

## How to Use This Guide

Every step has three parts:

- **Run** — the exact commands.
- **Expect** — what a correct result looks like, so you can tell "worked" from "silently didn't".
- **Why it matters** — the mental-model payload. Skip these and you'll finish the lab with typing practice and no understanding.

Sections marked **[Deep dive]** are additions to the original lab brief. They're optional in the sense that the checklist doesn't require them, and not optional in the sense that they're the parts that make Sub-labs 3.3–3.5 debuggable.

**Convention:** `$` = command on the Ubuntu host over SSH. `PS>` = command on your Windows workstation.

---

## Step 0 — Pre-Flight: Reclaim the Host

You have leftovers from a previous task. Deal with them first — a stale cluster is not just wasted RAM, it's a source of "why is `kubectl` talking to the wrong thing" confusion for the next three hours.

### 0.1 — See What's Actually Running

```bash
# Docker's view: containers, all states
docker ps -a

# Just the KinD node-containers (what you already found)
docker ps -a --filter label=io.x-k8s.kind.cluster \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Label "io.x-k8s.kind.cluster"}}'

# KinD's own view: which clusters does kind think exist?
kind get clusters

# kubectl's view: which clusters/contexts are in your kubeconfig?
kubectl config get-contexts
kubectl config current-context
```

**Expect:** `kind get clusters` prints `kind` (the default name, which is why your containers are `kind-control-plane`, `kind-worker`, `kind-worker2`). `kubectl config get-contexts` shows a context named `kind-kind` with a `*` next to it.

**Why it matters:** Three different tools each have their own idea of what exists, and they can disagree. `docker ps` shows containers. `kind get clusters` derives its answer from those container labels — it has no database. `kubectl config` is just a YAML file at `~/.kube/config` that can happily reference a cluster that was deleted months ago. When something is weird later, checking all three is the first move.

### 0.2 — Check Whether It's Worth Keeping

Short answer: no. Delete it.

Reasoning, so you're not just following orders:

- A 3-node KinD cluster idles at roughly 1.0–1.5 GB RAM and a steady trickle of CPU (etcd fsyncs, kubelet heartbeats, controller-manager reconcile loops every few seconds). That's real money on a lab VM.
- The Lab 3 series wants a cluster you defined, from a config file you can read. An inherited cluster from a previous task has unknown configuration — you don't know what feature gates, port mappings, or mounts it has.
- Deleting a cluster does not delete the `kindest/node` image from disk. So recreation is fast (~60–90s), because the expensive part — pulling a ~1 GB node image — is already done.

Confirm resources before and after so you can see the difference:

```bash
free -h
nproc
df -h /
docker system df
```

Rule of thumb for KinD: ~2 GB RAM and ~2 vCPU minimum for a 3-node cluster doing nothing; you want 4 GB+ free before starting Lab 3, since 3.2 onward adds real workloads.

### 0.3 — Stop Lab 02's Compose Stack

```bash
cd ~/multi-service-App
docker compose down

# Verify nothing from Lab 02 is left running
docker compose ps
docker ps
```

`docker compose down` removes containers and the Compose-created network, but keeps named volumes and images. If you want Lab 02's data gone too, `docker compose down -v` — but only if you're sure you don't need it.

### 0.4 — Delete the Old Cluster

```bash
kind delete cluster --name kind
```

**Expect:**

```
Deleting cluster "kind" ...
Deleted nodes: ["kind-control-plane" "kind-worker" "kind-worker2"]
```

`kind delete cluster` also removes the `kind-kind` context, cluster, and user entries from `~/.kube/config`. It's one of the tidier CLI tools in this space.

### 0.5 — Verify the Reclaim

```bash
docker ps -a --filter label=io.x-k8s.kind.cluster    # should print only the header row
kind get clusters                                     # "No kind clusters found."
kubectl config get-contexts                           # kind-kind should be gone
free -h                                               # compare against 0.2

# The 'kind' Docker bridge network survives cluster deletion — that's fine and expected.
docker network ls
```

**[Deep dive]** What KinD leaves behind on purpose:

```bash
# The node image — keep it, it makes cluster creation fast
docker images kindest/node

# Anonymous volumes KinD used for the nodes' containerd storage
docker volume ls
```

If `docker volume ls` shows a pile of dangling volumes and you're tight on disk:

```bash
docker volume ls -qf dangling=true          # look first
docker volume prune -f                      # then remove
```

> Do not run a blanket `docker system prune -a` — it would delete the `kindest/node` image and your Lab 02 app images, turning a 90-second cluster creation into a multi-gigabyte re-pull.

---

## Step 1 — Install / Verify kubectl and kind

Both binaries are already at `/usr/local/bin`. You're verifying and, if needed, updating — not installing from scratch.

### 1.1 — Check Versions

```bash
kind version
kubectl version --client
```

Note the two numbers that matter:

- `kind version` (e.g. `v0.33.0`) — the tool that builds clusters.
- `kubectl` client version (e.g. `v1.36.x`) — the tool that talks to clusters.

Your existing nodes were `kindest/node:v1.36.1`, which tells you the `kind` binary on this host is recent enough to ship a v1.36 default image.

### 1.2 — The Version Skew Rule You Need to Know

Kubernetes supports a ±1 minor version skew between `kubectl` and the API server. A v1.36 `kubectl` works against v1.35, v1.36, and v1.37 clusters. Two minors apart and you start hitting missing fields and odd errors.

`kind` has a separate compatibility relationship: each `kind` release is tested against a specific set of `kindest/node` image tags, listed in that release's notes. Mixing a very old `kind` binary with a very new node image is a classic source of "cluster created but nodes never go Ready".

### 1.3 — Update Either Tool (Only If You Want To)

```bash
# kubectl — latest stable
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check      # must print "kubectl: OK"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm -f kubectl kubectl.sha256
kubectl version --client
```

```bash
# kind — replace VERSION with the current release tag from
# https://github.com/kubernetes-sigs/kind/releases
KIND_VERSION=v0.33.0
curl -Lo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-amd64"
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind
kind version
```

> Always verify the checksum on `kubectl`. It's a root-owned binary that talks to your clusters; it's exactly the thing worth being paranoid about.

### 1.4 — Enable Shell Completion (Do This, It Pays for Itself in Ten Minutes)

```bash
sudo apt-get update && sudo apt-get install -y bash-completion

echo 'source <(kubectl completion bash)' >> ~/.bashrc
echo 'alias k=kubectl' >> ~/.bashrc
echo 'complete -o default -F __start_kubectl k' >> ~/.bashrc
echo 'source <(kind completion bash)' >> ~/.bashrc
source ~/.bashrc
```

Now `k get po <TAB>` completes real Pod names from the live cluster. Tab-completion against live cluster state is genuinely a learning tool — it shows you what resource types and object names exist without you having to guess.

### 1.5 — The Split You Must Be Clear On

| | `kind` | `kubectl` |
|---|---|---|
| Talks to | the Docker daemon | the Kubernetes API server |
| Creates | node-containers, i.e. the cluster itself | objects inside a cluster |
| Knows about Pods? | No. Zero awareness. | Yes, that's its whole job |
| Needed after cluster creation? | Only to delete the cluster or load images | Constantly |
| Works against EKS/AKS/GKE? | No, KinD-only | Yes, identical commands |

The common beginner error is reaching for `kind` when a workload misbehaves. `kind` cannot help you — as far as it's concerned, it built three Docker containers and its job is done. Everything above the node layer is `kubectl`'s territory, and the commands you learn here are byte-identical against a managed cloud cluster.

**[Deep dive]** — a third thing worth knowing exists: `crictl`, the CRI-level container tool, which lives inside each node-container. You'll use it in Step 3.6 to see the layer beneath Kubernetes.

---

## Step 2 — Write a KinD Config and Create the Cluster

### 2.1 — Make a Working Directory

```bash
mkdir -p ~/lab3/manifests
cd ~/lab3
```

### 2.2 — Write the Cluster Config

```bash
cat > ~/lab3/kind-lab3.yaml <<'EOF'
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
name: lab3

nodes:
  - role: control-plane
    # Map host ports into the control-plane node so NodePort Services
    # can be reached from outside the Docker network later (Sub-lab 3.4).
    # These are declared at CREATE time only — they cannot be added
    # to a running cluster. Hence declaring them now, before you need them.
    extraPortMappings:
      - containerPort: 30080
        hostPort: 30080
        protocol: TCP
      - containerPort: 30443
        hostPort: 30443
        protocol: TCP

  - role: worker
  - role: worker
EOF

cat ~/lab3/kind-lab3.yaml
```

Field by field:

- `apiVersion: kind.x-k8s.io/v1alpha4` — KinD's own config schema, not a Kubernetes API group. This file never reaches the API server; it's read by the `kind` binary on your laptop/host. Don't confuse it with the manifests you write in Step 5.
- `name: lab3` — names the cluster. Node containers become `lab3-control-plane`, `lab3-worker`, `lab3-worker2`; the kubeconfig context becomes `kind-lab3`. Naming it something other than `kind` is deliberate: if you ever see `kind-control-plane` again, you'll know it's a stray from the old task.
- `nodes:` — a list. Order matters only for the numeric suffixes. Three entries → three Docker containers → three Kubernetes Nodes.
- `extraPortMappings` — plain Docker `-p` port publishing on the node-container. This is the only way to reach a NodePort from outside the Docker bridge network, and it is immutable after creation. Getting this wrong is the #1 reason people delete and recreate KinD clusters.

> **Question:** why mapping the control plane to 2 different ports?
>
> One for HTTP, one for HTTPS. 30080 and 30443 mirror 80 and 443 (by default, NGINX listens on port 80 for HTTP, and port 443 is the default port for HTTPS).
>
> Example: `docker run --name my-nginx -p 8080:80 nginx`
> - `8080` = port on your computer/host
> - `80` = port inside the Docker container where NGINX is listening
>
> The numbers matter for a different reason: 30000–32767 is the NodePort range. Kubernetes only assigns Service NodePorts inside that window, so mapping host port 80 to container port 80 would be useless — no Service would ever land there. That's why the config uses 30080/30443 rather than 80/443.

**[Deep dive]** — options worth knowing about but not enabling today:

```yaml
networking:
  apiServerAddress: "0.0.0.0"   # expose the API server beyond 127.0.0.1
  apiServerPort: 6443
  disableDefaultCNI: false      # true = no kindnet, you install Calico/Cilium yourself
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/16"
```

Leave `apiServerAddress` at its default. It defaults to `127.0.0.1`, meaning the API server is only reachable from the Ubuntu host itself. That's the right security posture for a lab, and you'll access everything over SSH anyway. `disableDefaultCNI: true` is a fascinating exercise — it gives you a cluster where every Pod is stuck `Pending` until you install a CNI — but it's a different lab.

> **Question:** where is this configured? And are those the default?
>
> Same file, at the top level — a sibling of `nodes:`, not nested inside it. `networking` is cluster-wide, so it sits at the root.

### 2.3 — Create the Cluster

```bash
time kind create cluster --config ~/lab3/kind-lab3.yaml
```

**Expect** — read this output carefully, it's a summary of what a Kubernetes cluster is:

```
Creating cluster "lab3" ...
 ✓ Ensuring node image (kindest/node:v1.36.1) 🖼
 ✓ Preparing nodes 📦 📦 📦
 ✓ Writing configuration 📄
 ✓ Starting control-plane 🕹️
 ✓ Installing CNI 🔌
 ✓ Installing StorageClass 💾
 ✓ Joining worker nodes 🚜
Set kubectl context to "kind-lab3"
```

Each line maps to a real thing:

| Line | What actually happened |
|---|---|
| Ensuring node image | Docker image present (already cached — that's why this is fast) |
| Preparing nodes | Three containers started, each running systemd + containerd + kubelet |
| Writing configuration | kubeadm config + PKI certificates generated |
| Starting control-plane | `kubeadm init` — etcd, kube-apiserver, kube-scheduler, kube-controller-manager come up as static Pods |
| Installing CNI | kindnet DaemonSet applied — without this, no Pod networking, nodes stay NotReady |
| Installing StorageClass | local-path-provisioner, so PVCs can bind (matters in Sub-lab 3.5) |
| Joining worker nodes | `kubeadm join` on each worker, using a bootstrap token |

### 2.4 — Confirm at the Docker Layer First

```bash
docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'
```

**Expect:** three containers — `lab3-control-plane` (with your 30080/30443 mappings plus a random high port → 6443), `lab3-worker`, `lab3-worker2`.

**Why it matters:** This is the whole trick of KinD, made visible. A "Node" in a cloud cluster is a VM. Here it's a Docker container running an init system, a container runtime, and a kubelet. Every Pod you create is a container inside one of these containers. Nested, but not magic.

### 2.5 — Confirm at the Kubernetes Layer

```bash
kubectl config current-context      # kind-lab3
kubectl cluster-info
kubectl get nodes -o wide
```

**Expect:** three nodes, all `Ready`, one with role `control-plane` and two with role `<none>`.

> If nodes are stuck `NotReady` for more than ~90 seconds, jump to the Troubleshooting section at the bottom — the usual culprit is inotify limits.

### 2.6 — [Deep Dive] Look at the Same Cluster From Three Angles

```bash
# 1. Docker's view — nodes as containers
docker inspect lab3-worker --format '{{.State.Status}} {{.HostConfig.Memory}}'
```

> **Question:** why does this return "running 0"?
>
> The command prints two fields, so you're looking at two separate answers stuck together. Docker uses `0` to mean "no limit set," not "zero memory." It's the same convention as `docker run` without `-m`: the field exists. KinD deliberately doesn't set memory limits on its node containers.

```bash
# 2. Kubernetes' view — nodes as API objects
kubectl get node lab3-worker -o yaml | head -60

# 3. Inside the node — the processes that make it a node
docker exec lab3-worker ps -ef | grep -E 'kubelet|containerd' | grep -v grep
```

Then look at what the control-plane node advertises about itself:

```bash
kubectl describe node lab3-control-plane | sed -n '/Taints/,/Unschedulable/p'
# or this command returns the same:
kubectl get node lab3-control-plane -o jsonpath='{.spec.taints}'; echo
```

```
$ kubectl describe node lab3-control-plane | sed -n '/Taints/,/Unschedulable/p'
Taints:             node-role.kubernetes.io/control-plane:NoSchedule
Unschedulable:      false

$ kubectl describe node lab3-worker | sed -n '/Taints/,/Unschedulable/p'
Taints:             <none>
Unschedulable:      false
```

**Expect:** `Taints: node-role.kubernetes.io/control-plane:NoSchedule`

A **taint** is a mark on a Node that says "keep Pods off me." A **toleration** is a mark on a Pod that says "that particular warning doesn't apply to me."

The output you'll see: `Taints: node-role.kubernetes.io/control-plane:NoSchedule`

Three pieces:

- `node-role.kubernetes.io/control-plane` — the key, an arbitrary label-like string
- (no value here, it's empty)
- `NoSchedule` — the effect

`NoSchedule` means the scheduler won't place new Pods here unless they tolerate this exact taint. The other effects are `PreferNoSchedule` (a soft nudge, try elsewhere first) and `NoExecute` (harsher — also evicts Pods already running that don't tolerate it).

This is why every Pod you create lands on `lab3-worker` or `lab3-worker2`. Not luck, not load balancing. The control-plane is actively repelling them, and it's set up that way so a runaway workload can't starve etcd or the API server.

**Why it matters:** This one line explains an observation you're about to make in Step 5 — every Pod you create lands on a worker, never the control-plane. It isn't a coincidence or a scheduling preference. The taint actively repels Pods that don't carry a matching toleration. System components like kube-proxy and kindnet run there anyway because they do declare tolerations. Taints/tolerations are how Kubernetes says "this node is reserved", and seeing the mechanism now means it won't surprise you later.

> Taints and tolerations are **repulsion** — the node's opinion about what it will accept. That's the opposite direction from `nodeSelector` and affinity, which are **attraction** — the Pod's opinion about where it wants to go.

> **Question:** can you explain this better — `sed -n`? Taints? `/Unschedulable/p`?
>
> `kubectl describe node` prints about 60 lines. You only want a couple of them, so `sed` slices out a range. (See: GNU sed — GNU Project — Free Software Foundation.)

---

## Step 3 — Orient: Tour the Cluster Before Creating Anything

Resist the urge to deploy something. Ten minutes here saves an hour in Sub-lab 3.4.

### 3.1 — What's Already Running

```bash
kubectl get pods -A -o wide
```

> **Question:** explain this command — components are explained below, the only question here is why are there 2 CoreDNS pods, and what is the K8s equivalent to kindnet.

**Expect roughly:**

| Namespace | Pods |
|---|---|
| `kube-system` | `etcd-lab3-control-plane`, `kube-apiserver-...`, `kube-controller-manager-...`, `kube-scheduler-...`, `kube-proxy-xxxxx` ×3, `kindnet-xxxxx` ×3, `coredns-...` ×2 |
| `local-path-storage` | `local-path-provisioner-...` |

Note the pattern in the counts: some components run once (on the control-plane), some run once per node, some run as a replicated Deployment. That's not arbitrary — it follows from what each one does.

### 3.2 — Learn Each Component by What It Would Break

Say these out loud; the checklist asks you to explain CoreDNS and kube-proxy in one sentence each.

| Component | One-sentence job | If you killed it permanently |
|---|---|---|
| etcd | The cluster's only database — every object's desired and observed state lives here | Total loss. The cluster *is* etcd; everything else is a cache. |
| kube-apiserver | The single front door — every read and write goes through it, including from other components | Nothing can be read or changed; running Pods keep running |
| kube-scheduler | Assigns Pods with no `nodeName` to a suitable node | New Pods stay Pending forever; existing Pods unaffected |
| kube-controller-manager | Runs the reconcile loops (Deployment → ReplicaSet → Pod, node health, etc.) | Deployments stop self-healing — Step 5's magic goes away |
| kubelet | Per-node agent: makes reality match the Pods assigned to it, reports status back | That node goes NotReady, its Pods get evicted after a grace period |
| kube-proxy | Per-node: programs iptables/nftables rules so traffic to a Service's ClusterIP is DNAT'd to a real Pod IP | Services stop routing — Pod-to-Pod by IP still works, Service names/IPs don't |
| CoreDNS | Cluster DNS: resolves `svc-name.namespace.svc.cluster.local` to a Service ClusterIP | Nothing resolves by name; direct IPs still work |
| kindnet | KinD's minimal CNI: assigns Pod IPs and wires up cross-node Pod routing | Pods can't get IPs; nodes go NotReady |
| local-path-provisioner | Dynamically creates PersistentVolumes backed by node-local disk | PVCs stay Pending (relevant in Sub-lab 3.5) |

The "if you killed it" column is the useful one. Debugging is mostly running that logic backwards: DNS names don't resolve but IPs do → look at CoreDNS. Service IP doesn't route but Pod IP does → look at kube-proxy.

### 3.3 — Look at the Controllers by Their Real Shape

```bash
kubectl get daemonsets -n kube-system
```

A DaemonSet in Kubernetes is a workload type that ensures one copy of a pod runs on each node, or on selected nodes. DaemonSets are commonly used for services that need to run on every node in the cluster, such as: log collectors, monitoring agents, network plugins, storage agents, security agents. For example, if your cluster has 5 nodes, a DaemonSet usually creates 5 pods — one pod per node.

```
$ kubectl get daemonsets -n kube-system
NAME         DESIRED   CURRENT   READY   UP-TO-DATE   AVAILABLE   NODE SELECTOR            AGE
kindnet          3         3        3         3            3         kubernetes.io/os=linux   35m
kube-proxy       3         3        3         3            3         kubernetes.io/os=linux   35m
```

```bash
kubectl get deployments -n kube-system
```

A Deployment in Kubernetes is an object that manages application pods and keeps them running in the desired state. CoreDNS is usually deployed as a Kubernetes Deployment in the `kube-system` namespace.

Why is CoreDNS a Deployment? CoreDNS runs as pods, but Kubernetes manages those pods using a Deployment. A Deployment is used because CoreDNS should be: always running, highly available, automatically restarted if it fails, easy to scale, easy to update/roll back.

```
$ kubectl get deployments -n kube-system
NAME      READY   UP-TO-DATE   AVAILABLE   AGE
coredns   2/2     2            2           35m
```

> **Question:** Also why does `get deployments` return CoreDNS, and what is kindnet — is this something K8s native or KinD?

**Why two CoreDNS Pods:** because DNS is a single point of failure for the entire cluster, and one Pod means one node reboot takes down name resolution for everything. The `2` isn't computed from your node count — it's a hardcoded default in kubeadm's CoreDNS manifest. You'd get 2 on a 3-node cluster, a 50-node cluster, or a 1-node cluster. On single-node KinD one of them just sits Pending forever, unschedulable and harmless.

**What kindnet is the equivalent of:** kindnet is a CNI plugin — the component that gives Pods IP addresses and makes Pod-to-Pod traffic work across nodes. There is no "the" Kubernetes equivalent, and that's the important part. Kubernetes deliberately ships no networking implementation. It defines an interface (the Container Network Interface spec) and requires you to install something that implements it. A cluster with no CNI has nodes stuck NotReady and Pods stuck ContainerCreating forever.

The ones you'd meet in the wild:

| Plugin | Where you see it |
|---|---|
| Calico | The most common on-prem / self-managed choice. NetworkPolicy support, BGP routing. |
| Cilium | eBPF-based. Increasingly the default for new builds; can replace kube-proxy entirely. |
| Flannel | Simple overlay, minimal features. kindnet is closest to this. |
| AWS VPC CNI | EKS default — Pods get real VPC IPs. |
| Azure CNI / Cloud-native | AKS. |
| GKE's netd | GKE. |

**Expect:** kube-proxy and kindnet as DaemonSets with DESIRED 3; coredns as a Deployment with 2/2.

**Why it matters:** The shape encodes the requirement. kube-proxy must program iptables on every node, so it's a DaemonSet — "one Pod per node, automatically, including nodes added later". CoreDNS just needs to be reachable and highly available, so it's a Deployment with 2 replicas that the scheduler places wherever. When you design your own workloads in 3.2, "DaemonSet or Deployment?" is answered by exactly this question: does this need to run on every node, or just somewhere, N times?

### 3.4 — Watch a Controller Do Its Job

```bash
kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.spec.template.spec.tolerations}' | python3 -m json.tool
```

There's the toleration that lets kube-proxy run on the tainted control-plane node — the other half of the taint story from Step 2.6.

```
$ kubectl get daemonset kube-proxy -n kube-system -o jsonpath='{.spec.template.spec.tolerations}' | python3 -m json.tool
[
    {
        "operator": "Exists"
    }
]
```

> **Question:** what is this?
>
> `kubectl get daemonset kube-proxy -n kube-system -o yaml` (this is the entire specification)

Every `kubectl get` follows this pattern: what kind of object, which specific one, and where it lives. It's the same as asking for a file — you need the type of thing, its name, and its directory.

- `daemonset` is the type of object. Like `pod`, `service`, `deployment`.
- `kube-proxy` is the name of one particular DaemonSet.
- `kube-system` is the namespace it lives in.

**DaemonSet:** a controller that guarantees one copy of this Pod on every node.

**kube-proxy:** the component that makes Services actually route traffic.

### 3.5 — Prove CoreDNS Is a Real Service

```bash
kubectl get svc -n kube-system kube-dns
```

```
$ kubectl get svc -n kube-system kube-dns
NAME       TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)                  AGE
kube-dns   ClusterIP   10.96.0.10   <none>        53/UDP,53/TCP,9153/TCP   41m
```

Port 53 is the standard DNS port.

```bash
kubectl get endpointslices -n kube-system -l k8s-app=kube-dns
```

An EndpointSlice is a Kubernetes object that tracks the real backend network endpoints behind a Service. A Service gives you a stable IP. EndpointSlices tell Kubernetes which actual pods are behind that Service.

```
$ kubectl get endpointslices -n kube-system -l k8s-app=kube-dns
NAME             ADDRESSTYPE   PORTS        ENDPOINTS               AGE
kube-dns-mxt2f   IPv4          53,53,9153   10.244.0.2,10.244.0.3   42m
```

**Expect:** a ClusterIP (typically `10.96.0.10`) and an EndpointSlice listing the two CoreDNS Pod IPs.

**Why it matters:** Every Pod's `/etc/resolv.conf` is written by the kubelet to point at that ClusterIP. Which means DNS itself is served through the same Service abstraction you're about to build by hand — kube-proxy routes DNS traffic to CoreDNS exactly the same way it'll route your traffic to nginx. It's turtles all the way down, and that's reassuring, not confusing.

### 3.6 — [Deep Dive] Go Under the API

**Static Pods** — the bootstrap trick that solves the chicken-and-egg problem:

```bash
docker exec lab3-control-plane ls -l /etc/kubernetes/manifests/
```

```
$ docker exec lab3-control-plane ls -l /etc/kubernetes/manifests/
total 16
-rw------- 1 root root 2604 Sep  6 21:16 etcd.yaml
-rw------- 1 root root 3968 Sep  6 21:16 kube-apiserver.yaml
-rw------- 1 root root 3264 Sep  6 21:16 kube-controller-manager.yaml
-rw------- 1 root root 1726 Sep  6 21:16 kube-scheduler.yaml
```

```bash
docker exec lab3-control-plane head -25 /etc/kubernetes/manifests/kube-apiserver.yaml
```

**Why it matters:** How do you start the API server using Kubernetes, when Kubernetes needs the API server? You don't. The kubelet watches that directory on disk and starts anything it finds there directly, with no API server involved. Those Pods then appear in the API afterward as read-only mirror objects. That's why `kubectl delete pod etcd-lab3-control-plane` appears to work and the Pod immediately comes back — you deleted the mirror, not the thing.

**The container runtime, below Kubernetes:**

```bash
docker exec lab3-control-plane crictl ps
docker exec lab3-worker crictl ps
```

> Explanation: the `crictl` part is showing you that Kubernetes doesn't actually run containers. Something below it does, and `crictl` lets you look at that layer directly.
>
> The stack:
> ```
> kubectl          ← you, talking to the API server
>    │
> API server       ← stores "there should be a Pod"
>    │
> kubelet          ← on each node, reads that and says "make it so"
>    │
> containerd       ← actually creates and runs the containers
>    │
> Linux kernel     ← namespaces, cgroups
> ```
>
> `kubectl` sees Pods. `containerd` has never heard of a Pod. It only knows about containers. The kubelet is the translator between those two worlds.
>
> `crictl` is a debugging tool that talks straight to containerd, skipping the top three layers. So running it shows you the same workloads with all the Kubernetes vocabulary stripped off.
>
> Why you'd ever care: when something is broken below Kubernetes, `kubectl` goes blind. If containerd is wedged, or an image is half-pulled, or a container is running that Kubernetes doesn't know about, `kubectl get pods` will show you a clean, calm, completely useless picture. `crictl` is how you check whether reality matches what the API claims.

**Raw API access:**

```bash
kubectl get --raw /healthz              # returns "ok" if the API server is alive
kubectl get --raw /livez?verbose        # same check, but verbose lists every subsystem tested
kubectl api-resources | head -40        # the catalogue of every object type this cluster understands
kubectl api-versions | head -20
```

`kubectl api-resources` is the single most underrated command in Kubernetes. It's a live catalogue of every object type this cluster understands, with the short names (`po`, `deploy`, `svc`) and whether each is namespaced. When you hit a CRD in a real cluster, this is how you find out it exists.

**See the HTTP under the CLI:**

```bash
kubectl get pods -n kube-system --v=8 2>&1 | head -30
```

`kubectl` is a REST client. Every command is GET/POST/PATCH/DELETE against the API server. Seeing the raw request once permanently changes how you think about "the API server is the only front door".

**Self-documenting schemas:**

```bash
kubectl explain pod.spec.containers
kubectl explain deployment.spec.strategy --recursive | head -20
```

Use this instead of googling YAML field names. It reads the schema from your cluster, so it's always correct for your version.

---

## Step 4 — Imperative Toy: Pod → Service → Reach It

The goal is to feel the boundary between the two objects. You create a Pod. It runs. It is completely unreachable by name. Then you create a separate object, and suddenly it is. That gap is the lesson.

### 4.1 — Create a Bare Pod Imperatively

```bash
kubectl run web-imperative --image=nginx:alpine --port=80   # create a single pod called web-imperative
kubectl get pods -o wide
```

**Expect:** `Running` within a few seconds, with an IP from the Pod CIDR (`10.244.x.x`) and NODE = one of the workers, never the control-plane (Step 2.6's taint at work).

**[Deep dive]** — see what that command actually built, without building it:

```bash
kubectl run web-dry --image=nginx:alpine --port=80 --dry-run=client -o yaml
```

`--dry-run=client` — build the object locally, but don't send it to the cluster. Nothing is created. No Pod named `web-dry` will exist afterward.

This is the bridge from imperative to declarative, and the single most useful `kubectl` trick there is. `--dry-run=client -o yaml` turns any imperative command into the manifest it would have created. In Step 5 you'll write YAML by hand once — after that, generate a skeleton this way and edit it.

Note the label `kubectl` auto-applied: `run: web-imperative`. Remember it; it's about to matter.

### 4.2 — Prove It Exists but Isn't Addressable

```bash
POD_IP=$(kubectl get pod web-imperative -o jsonpath='{.status.podIP}')
echo "$POD_IP"

# Reach it by raw IP from another Pod — works
kubectl run tmp-shell --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=3 "http://${POD_IP}" | head -5

# Now try it by name — fails
kubectl run tmp-shell --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=3 "http://web-imperative" || echo "failed as expected"

kubectl delete pod tmp-shell
```

**Expect:** the first returns nginx's welcome HTML. The second fails to resolve.

**Why it matters:** This is the payload of the whole step. The Pod is running and serving traffic. It has an IP. And it is still useless in any real system, because that IP is ephemeral — delete the Pod, a replacement gets a different one — and nothing can find it by name. A Pod without a Service is a fact nobody can look up.

Also note what `--rm -it --restart=Never` did: created a Pod, attached your terminal, and deleted it on exit. That throwaway-debug-Pod pattern is something you'll use constantly for the rest of your Kubernetes life.

### 4.3 — Create the Service Imperatively

A Service is a stable identity for a changing set of Pods.

Pods are disposable by design. They get deleted, rescheduled, scaled up and down, replaced during a rollout. Every replacement has a different name and a different IP. So nothing can point at a Pod and expect that pointer to keep working.

A Service is the fixed thing you point at instead. It has:

- a name that doesn't change (`web-imperative-svc`)
- an IP that doesn't change (its ClusterIP)
- a label query describing which Pods it currently means

```bash
kubectl expose pod web-imperative --name=web-imperative-svc --port=80 --target-port=80
```

`expose` — create a Service in front of something.

```bash
kubectl get svc web-imperative-svc
```

`10.96.116.10` — randomly allocated from free addresses. See `kubectl get svc -A`.

```bash
kubectl get endpointslices -l kubernetes.io/service-name=web-imperative-svc
```

**Expect:** a ClusterIP from `10.96.0.0/16`, and an EndpointSlice containing your Pod's IP.

Inspect the selector `kubectl` inferred:

```bash
kubectl get svc web-imperative-svc -o jsonpath='{.spec.selector}'; echo
```

**Expect:** `{"run":"web-imperative"}` — it copied the Pod's label.

**Why it matters:** The Service does not reference the Pod by name. It has no idea the Pod exists. It holds a label selector, and a controller continuously scans for Pods matching it and writes their IPs into an EndpointSlice. This indirection is the core design idea of Kubernetes: components are coupled by label queries, never by direct reference. It's what makes rolling updates work — new Pods with matching labels join the Service automatically; old ones drop out as they terminate.

### 4.4 — Reach It by Name

```bash
kubectl run tmp-shell --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=3 "http://web-imperative-svc" | head -5

# The full DNS name CoreDNS actually serves
kubectl run tmp-shell --rm -it --image=busybox:1.36 --restart=Never -- \
  nslookup web-imperative-svc.default.svc.cluster.local
```

Same Pod, same content — but now reachable by a stable name backed by a stable IP, both of which outlive any individual Pod. That's the entire value proposition of a Service in one sentence.

### 4.5 — [Deep Dive] Break the Selector Deliberately

This five-minute detour teaches you to diagnose the single most common Service failure in existence.

```bash
kubectl patch svc web-imperative-svc -p '{"spec":{"selector":{"run":"typo-here"}}}'
kubectl get endpointslices -l kubernetes.io/service-name=web-imperative-svc

kubectl run tmp-shell --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=3 "http://web-imperative-svc" || echo "<-- expected: connection refused/timeout"

# Repair
kubectl patch svc web-imperative-svc -p '{"spec":{"selector":{"run":"web-imperative"}}}'
kubectl get endpointslices -l kubernetes.io/service-name=web-imperative-svc
```

**Expect:** with the bad selector, the EndpointSlice has no addresses (or the slice disappears), and connections fail. Fix the selector, endpoints repopulate within a second.

**Why it matters:** In production this presents as "the Service returns nothing" with no error anywhere — the Service object is Running, the Pods are Running, events are clean. The only symptom is empty endpoints. Burn this in now:

> Service not working? `kubectl get endpointslices` first. Empty endpoints = your selector doesn't match your Pod labels. Every time.

### 4.6 — Reach It From Your Windows Workstation via Port-Forward

Here's the wrinkle the lab brief glosses over: `kubectl port-forward` binds to `127.0.0.1` on the Ubuntu host, not to `172.31.17.54`. So a browser on your Windows box can't reach it by default. Two ways to solve it.

**Option A — SSH tunnel (recommended).**

On Ubuntu:

```bash
kubectl port-forward pod/web-imperative 8080:80
# leave running
```

On Windows, in a second terminal:

```powershell
ssh -L 8080:localhost:8080 kemel@172.31.17.54
```

Then browse to `http://localhost:8080`. Traffic path: Windows browser → SSH tunnel → Ubuntu localhost:8080 → `kubectl port-forward` → API server → kubelet → Pod:80.

**Option B — bind port-forward to all interfaces.**

```bash
kubectl port-forward --address 0.0.0.0 pod/web-imperative 8080:80
```

Then browse to `http://172.31.17.54:8080`. Simpler, but it exposes the Pod to your whole subnet with no auth. Fine on a lab network; know that you're doing it.

Also try forwarding to the Service rather than the Pod:

```bash
kubectl port-forward svc/web-imperative-svc 8081:80
```

**[Deep dive]** — the thing people get wrong about `port-forward`: even when you target a Service, `port-forward` resolves it to one Pod and tunnels to that single Pod. It does not load-balance. It bypasses kube-proxy entirely. It's a debugging tunnel through the API server, not a traffic path — which is why the lab brief calls it "not a real access pattern". Real ingress comes in Sub-lab 3.4 via NodePort (hence those `extraPortMappings` you declared in Step 2) and Ingress.

Stop the forward with `Ctrl-C` when done.

---

## Step 5 — Declarative Rebuild and the Self-Healing Contrast

This is the most important step in the sub-lab. Take your time.

### 5.1 — Delete the Imperative Objects

```bash
kubectl delete pod web-imperative
kubectl delete svc web-imperative-svc
kubectl get all
```

**Expect:** only `service/kubernetes` remains. See the note in the Verification section — that one is permanent and normal.

### 5.2 — Write the Manifests

```bash
cd ~/lab3/manifests

cat > pod.yaml <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: web-bare
  labels:
    app: web-bare
spec:
  containers:
    - name: nginx
      image: nginx:alpine
      ports:
        - containerPort: 80
EOF
```

This creates a single NGINX pod. But because it is just a bare Pod, Kubernetes will not truly "self-heal" it in the same way a Deployment does. If this Pod is deleted, Kubernetes does not recreate it automatically.

```bash
cat > deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web-deploy
  labels:
    app: web-deploy
spec:
  replicas: 3
  selector:
    matchLabels:
      app: web-deploy          # MUST match template.metadata.labels below
  template:
    metadata:
      labels:
        app: web-deploy        # the label stamped on every Pod it creates
    spec:
      containers:
        - name: nginx
          image: nginx:alpine
          ports:
            - containerPort: 80
          resources:
            requests:
              cpu: 10m
              memory: 16Mi
            limits:
              memory: 64Mi
EOF
```

The Deployment does not directly run containers itself. It manages Pods for you. If one of the 3 pods dies or is deleted, the Deployment notices:

- Desired pods: 3
- Current pods: 2

Then it creates a new one. That is the self-healing behavior.

```bash
cat > service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: web-deploy-svc
spec:
  type: ClusterIP
  selector:
    app: web-deploy            # matches the Deployment's Pod labels, NOT the Deployment itself
  ports:
    - port: 80
      targetPort: 80
      protocol: TCP
EOF

ls -l
```

The Service gives your pods a stable internal network address. Why is that needed? Because Deployment pods are temporary. Their names and IP addresses can change. The Service stays stable and forwards traffic to whichever pods currently match this label: `app: web-deploy`. So the Service is basically saying: send traffic to pods labeled `app=web-deploy`.

Three things in these files deserve a hard look:

1. **`apiVersion` differs per kind.** Pod and Service are `v1` (core group, there since the beginning). Deployment is `apps/v1`. Getting this wrong produces "no matches for kind" — and `kubectl explain deployment` tells you the right one.

2. **The Deployment has labels in two places and they are not the same thing.**
   - `metadata.labels` — labels on the Deployment object itself. Cosmetic; used for your own filtering.
   - `spec.selector.matchLabels` — which Pods this Deployment considers its own. Immutable after creation.
   - `spec.template.metadata.labels` — the labels stamped onto Pods it creates.

   The last two must match or the API rejects the object. That's the API server saving you from a Deployment that creates Pods it then refuses to recognise, spawning infinitely.

3. **Three separate label relationships are in play:**

    ```
    Deployment.spec.selector ──matches──▶ Pod labels ◀──matches── Service.spec.selector
    ```

   The Service and the Deployment have no direct link whatsoever. They both independently point at the same Pod labels. You could delete the Deployment and the Service would carry on selecting nothing, perfectly healthy, waiting. Internalising this decoupling is what makes Kubernetes debugging tractable.

### 5.3 — Apply and Observe

```bash
kubectl apply -f pod.yaml
kubectl apply -f deployment.yaml
kubectl apply -f service.yaml

kubectl get pods -o wide
kubectl get deploy,rs,svc
kubectl get endpointslices -l kubernetes.io/service-name=web-deploy-svc
```

**Expect:** 4 Pods (1 `web-bare` + 3 `web-deploy-<rshash>-<podhash>`), spread across both workers. A ReplicaSet you never asked for. Three IPs in the EndpointSlice.

### 5.4 — The Layer You Didn't Create

```bash
kubectl get rs -o wide
kubectl get pod -l app=web-deploy -o jsonpath='{.items[0].metadata.ownerReferences}' | python3 -m json.tool
kubectl get rs -o jsonpath='{.items[0].metadata.ownerReferences}' | python3 -m json.tool
```

**Expect:** the Pod is owned by a ReplicaSet, and the ReplicaSet is owned by the Deployment.

```
Deployment ──owns──▶ ReplicaSet ──owns──▶ Pod ×3
   (rollout strategy)      (count enforcement)    (the actual thing)
```

**Why it matters:** People say "a Deployment manages Pods" and it's a useful simplification, but the ReplicaSet in the middle is where the count is actually enforced — and it's the mechanism behind rolling updates. When you change the image, the Deployment creates a second ReplicaSet and shifts replicas from old to new. That's why `kubectl rollout undo` works: the old ReplicaSet is still sitting there at 0 replicas, ready to scale back up. Those `ownerReferences` are also what make cascading deletion work — delete the Deployment and garbage collection walks the chain down.

### 5.5 — The Self-Healing Experiment (the Centrepiece)

Open two SSH sessions. In the first, start a watch:

```bash
kubectl get pods -w
```

In the second, kill a Deployment-managed Pod:

```bash
VICTIM=$(kubectl get pods -l app=web-deploy -o jsonpath='{.items[0].metadata.name}')
echo "Deleting $VICTIM"
kubectl delete pod "$VICTIM"
```

**Expect in the watch window:** the victim goes `Terminating`, and before it has even finished, a brand-new Pod with a different name appears as `Pending` → `ContainerCreating` → `Running`. Replica count never meaningfully drops below 3. Elapsed time: a couple of seconds.

Now the contrast — kill the bare Pod:

```bash
kubectl delete pod web-bare
kubectl get pods
sleep 20
kubectl get pods
```

**Expect:** `web-bare` is gone. It stays gone. Forever. Nothing notices, nothing complains, no event is logged as a problem.

Read the trail:

```bash
kubectl get events --sort-by=.lastTimestamp | tail -20
```

You'll see `SuccessfulCreate` from the replicaset controller for the replacement, and nothing at all for `web-bare`.

**Why it matters — the sentence to remember:**

> A Pod is a fact. A Deployment is a promise.

A Pod records that a container should exist right now. When it's deleted, the fact is simply no longer true, and Kubernetes is done. A Deployment records a standing intent — "three Pods matching this template should exist" — and a controller re-evaluates that intent in a loop, forever. Deleting a Pod doesn't break the promise; it creates a gap between desired and actual state, and the controller closes it within a second.

This is the **reconciliation loop**, and it is the fundamental idea of Kubernetes. Every controller in the system is the same shape: read desired state, observe actual state, take one step to close the gap, repeat. Once you see everything as instances of that loop, the whole system gets predictable — and the debugging question is always the same: what's the desired state, what's the actual state, and which controller is supposed to close the gap?

### 5.6 — [Deep Dive] Push the Loop Harder

Try to defeat it:

```bash
kubectl delete pod -l app=web-deploy      # kill all three at once
kubectl get pods -w                       # all three come back
```

Scale it, imperatively and declaratively:

```bash
kubectl scale deployment web-deploy --replicas=5
kubectl get pods -l app=web-deploy
kubectl get endpointslices -l kubernetes.io/service-name=web-deploy-svc   # 5 IPs now, automatically

kubectl scale deployment web-deploy --replicas=3
```

Notice the Service tracked the change with zero intervention. That's the label-selector indirection paying off.

See the drift `kubectl scale` created:

```bash
kubectl scale deployment web-deploy --replicas=5
kubectl diff -f deployment.yaml            # shows live=5 vs file=3
```

`kubectl diff` shows differences between the local manifest and the live cluster object.

```bash
kubectl apply -f deployment.yaml           # snaps back to 3
```

`kubectl diff` is your dry run against live state. This is also the moment to feel why imperative commands are discouraged day to day: `kubectl scale` produced state that exists nowhere in Git, and the next `apply` silently reverted someone's change.

Watch a rolling update:

```bash
kubectl set image deployment/web-deploy nginx=nginx:1.27-alpine
kubectl rollout status deployment/web-deploy
kubectl get rs                              # two ReplicaSets now: old at 0, new at 3
kubectl rollout history deployment/web-deploy
kubectl rollout undo deployment/web-deploy
kubectl get rs                              # they swap back
```

Delete the ReplicaSet instead of the Deployment:

```bash
RS=$(kubectl get rs -l app=web-deploy -o jsonpath='{.items[0].metadata.name}')
kubectl delete rs "$RS"
kubectl get rs,pods
```

The Deployment notices its ReplicaSet vanished and creates a fresh one. Reconciliation operates at every layer, not just at the Pod layer.

**Node-level self-healing** — see the scheduler react:

```bash
kubectl get pods -o wide                       # note the distribution
kubectl cordon lab3-worker2                    # mark unschedulable
kubectl drain lab3-worker2 --ignore-daemonsets --delete-emptydir-data
kubectl get pods -o wide                       # everything rescheduled onto lab3-worker
kubectl get nodes                              # worker2: Ready,SchedulingDisabled

kubectl uncordon lab3-worker2
kubectl get nodes
```

**Why it matters:** This is a controlled rehearsal of a node failure — precisely what happens during a cloud node upgrade. Note that existing Pods do not rebalance back onto worker2 after `uncordon`; the scheduler only places new Pods. Kubernetes self-heals, it doesn't continuously optimise placement.

**Cascading deletion, made visible:**

```bash
kubectl delete deployment web-deploy --cascade=orphan
kubectl get pods            # Pods survive! Now unowned and unmanaged
kubectl get rs              # ReplicaSet survives too

# Clean up the orphans, then rebuild properly
kubectl delete rs -l app=web-deploy
kubectl apply -f deployment.yaml
```

`--cascade=orphan` severs the `ownerReferences`, and suddenly those Pods are back to being bare facts. It's a nice demonstration that ownership is just a field, not a deep structural bond.

---

## Step 6 — Create the multi-service-app Namespace

### 6.1 — Create It

```bash
kubectl create namespace multi-service-app
kubectl get namespaces
```

Or declaratively, which is the better habit:

```bash
cat > ~/lab3/manifests/namespace.yaml <<'EOF'
apiVersion: v1
kind: Namespace
metadata:
  name: multi-service-app
  labels:
    lab: "3"
    purpose: multi-service-app
EOF

kubectl apply -f ~/lab3/manifests/namespace.yaml
```

### 6.2 — Set It as Your Context Default

```bash
kubectl config set-context --current --namespace=multi-service-app
kubectl config view --minify | grep namespace:
```

**Expect:** `namespace: multi-service-app`

This edits your local `~/.kube/config`. It changes nothing in the cluster — it only changes what `kubectl` assumes when you omit `-n`.

### 6.3 — Demonstrate the Isolation

```bash
kubectl get all                              # near-empty: this is multi-service-app now
kubectl get all -n default                   # your toys, untouched
kubectl get pods -A | head -20               # everything, everywhere
```

**Why it matters:** Your toy objects didn't move, change, or notice. A namespace is a naming and scoping boundary in etcd — it partitions object names (you can have a `web-deploy` in each namespace), and it's the unit that RBAC, ResourceQuotas, and NetworkPolicies attach to.

Crucially, note what it is not: by default it is **not** a network boundary. A Pod in `default` can reach a Service in `multi-service-app` right now, no policy required. Namespaces become a network boundary only when you add NetworkPolicies.

### 6.4 — [Deep Dive] Cross-Namespace DNS

```bash
kubectl run tmp-shell -n multi-service-app --rm -it --image=busybox:1.36 --restart=Never -- \
  wget -qO- --timeout=3 "http://web-deploy-svc.default.svc.cluster.local" | head -5

kubectl delete pod tmp-shell
```

**Expect:** nginx HTML. From a different namespace, with no policy, no config.

Now decode the DNS name — the pattern you'll use constantly in Sub-lab 3.3:

```
web-deploy-svc . default . svc . cluster.local
   Service       Namespace  type    cluster domain
```

Short name (`web-deploy-svc`) works within the same namespace, because the kubelet writes a search path into every Pod's `resolv.conf`:

```bash
kubectl run tmp-shell -n multi-service-app --rm -it --image=busybox:1.36 --restart=Never -- \
  cat /etc/resolv.conf
```

**Expect:** `nameserver 10.96.0.10` and a `search multi-service-app.svc.cluster.local svc.cluster.local cluster.local` line. That search path is precisely why a bare Service name resolves in-namespace but needs qualifying across namespaces — and why a cross-namespace call that "mysteriously" fails is usually a missing suffix, not a broken Service.

**[Deep dive]** Namespaced vs cluster-scoped:

```bash
kubectl api-resources --namespaced=true  | head -20
kubectl api-resources --namespaced=false | head -20
```

Nodes, PersistentVolumes, StorageClasses, ClusterRoles and Namespaces themselves are cluster-scoped — `kubectl get nodes -n whatever` ignores the flag entirely. Knowing which bucket a resource is in saves confusion when `-n` seems to have no effect.

---

## Step 7 — Clean Up Everything From This Sub-Lab

### 7.1 — Delete the Toys

```bash
kubectl delete -f ~/lab3/manifests/deployment.yaml -n default
kubectl delete -f ~/lab3/manifests/service.yaml    -n default
kubectl delete -f ~/lab3/manifests/pod.yaml        -n default 2>/dev/null || true
```

Or apply the whole directory in reverse — but exclude the namespace file, which you're keeping:

```bash
kubectl delete pod,deployment,service --all -n default
```

Belt and braces:

```bash
kubectl delete pod --all -n default
kubectl delete deployment --all -n default
kubectl delete rs --all -n default
```

### 7.2 — Verify

```bash
kubectl get all -n default
kubectl get all -n multi-service-app
kubectl get pods -A
```

### 7.3 — ⚠️ The Checklist Item That's Slightly Wrong

The lab's verification checklist says `kubectl get all -n default` should "come back empty". It won't, and shouldn't. You will always see:

```
NAME                 TYPE        CLUSTER-IP   EXTERNAL-IP   PORT(S)   AGE
service/kubernetes   ClusterIP   10.96.0.1    <none>        443/TCP   25m
```

`service/kubernetes` is how Pods reach the API server from inside the cluster. It's created at cluster bootstrap, in `default`, and the API server recreates it within seconds if you delete it. Try it if you like — that's another reconciliation loop.

So the correct pass condition is: `default` contains nothing but `service/kubernetes`.

Also note that `kubectl get all` is a lie of a command name — it shows a curated handful of common types, not *all* resources. It omits ConfigMaps, Secrets, PVCs, Ingresses, ServiceAccounts, and every CRD. For a genuine sweep:

```bash
kubectl api-resources --verbs=list --namespaced -o name \
  | xargs -n 1 kubectl get --show-kind --ignore-not-found -n default
```

### 7.4 — What to Keep

Keep: the `lab3` cluster, the `multi-service-app` namespace, `~/lab3/manifests/`, and your context default. Sub-lab 3.2 builds on all of it.

Don't run `kind delete cluster --name lab3` unless you intend to rebuild — and if you do rebuild, remember that the `extraPortMappings` only exist because they were in the config file, so recreate from `~/lab3/kind-lab3.yaml`, not from `kind create cluster` bare.

Optional tidy-up of the untracked stuff you created ad hoc:

```bash
kubectl get pods -A | grep tmp-shell        # should be nothing; --rm cleans up
docker system df                             # check disk
```

---

## Verification Checklist (Corrected + Expanded)

| # | Check | Command | Pass condition |
|---|---|---|---|
| 1 | 3 nodes Ready | `kubectl get nodes` | 1 control-plane + 2 workers, all Ready |
| 2 | System Pods | `kubectl get pods -n kube-system` | CoreDNS + kube-proxy Running, and you can state each one's job |
| 3 | Old cluster gone | `kind get clusters` | only `lab3`; no `kind-*` containers in `docker ps -a` |
| 4 | Imperative Pod+Svc reached | (done in Step 4) | nginx page seen over port-forward |
| 5 | Self-healing | (done in Step 5.5) | Deployment Pod replaced automatically; bare Pod not replaced |
| 6 | Ownership chain understood | `kubectl get rs` during 5.4 | Deployment → ReplicaSet → Pod |
| 7 | Namespace exists + is default | `kubectl config view --minify \| grep namespace` | `multi-service-app` |
| 8 | `default` clean | `kubectl get all -n default` | only `service/kubernetes` |
| 9 | `multi-service-app` clean | `kubectl get all -n multi-service-app` | `No resources found.` |
| 10 | Lab 02 stopped | `docker ps` | only the three `lab3-*` node containers |

## Self-Test — Answer Without Looking

1. Why did every Pod you created land on a worker and never the control-plane?
2. A Service exists, its Pods are Running, but nothing can reach it. What's the first command you run?
3. What is between a Deployment and its Pods, and why does it exist?
4. You delete a Pod created by a Deployment and one created directly. Describe the different outcomes and explain why in terms of desired vs actual state.
5. What does kube-proxy actually do to a node when you create a Service?
6. Why is `web-deploy-svc` resolvable from `default` but not from `multi-service-app` without a suffix?
7. Why can't you add a NodePort mapping to a running KinD cluster?

If any of those are shaky, the corresponding step is worth a second pass. Question 4 is the one that matters most.

---

## Troubleshooting

**Nodes stuck NotReady, or cluster creation hangs at "Joining worker nodes".** Almost always inotify exhaustion — each kubelet and containerd consumes watches, and the defaults are too low for multi-node KinD.

```bash
cat /proc/sys/fs/inotify/max_user_watches
cat /proc/sys/fs/inotify/max_user_instances

sudo tee /etc/sysctl.d/99-kind.conf >/dev/null <<'EOF'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
EOF
sudo sysctl --system

kind delete cluster --name lab3
kind create cluster --config ~/lab3/kind-lab3.yaml
```

**`kubectl` says connection refused to `127.0.0.1:PORT`.** Your kubeconfig points at a cluster that no longer exists, or the context is wrong.

```bash
kubectl config get-contexts
kubectl config use-context kind-lab3
kind export kubeconfig --name lab3      # regenerate the entry
```

**Pod stuck Pending.**

```bash
kubectl describe pod <name> | tail -20
```

Read the Events section. Usual causes: insufficient CPU/memory on nodes, no node tolerates the Pod, or (if you ever set `disableDefaultCNI`) no CNI.

**Pod stuck ContainerCreating.** Usually an image pull. KinD nodes pull from Docker Hub independently of your host's Docker image cache — a `docker pull` on the host does not make the image available inside the cluster.

```bash
kubectl describe pod <name> | grep -A5 Events
docker exec lab3-worker crictl images
```

The fix in later sub-labs (for your own locally built images) is:

```bash
kind load docker-image myapp:tag --name lab3
```

Note that down — Sub-lab 3.2 will need it the moment you try to run an image you built yourself, and "`ErrImagePull` for an image that's definitely on my machine" catches almost everyone once.

**CrashLoopBackOff.**

```bash
kubectl logs <pod>              # current attempt
kubectl logs <pod> --previous   # the attempt that crashed — usually the useful one
kubectl describe pod <pod>
```

**Host is thrashing / swapping.**

```bash
free -h; docker stats --no-stream
```

Drop to a single worker in `kind-lab3.yaml` and recreate. Two nodes still demonstrates scheduling; three is nicer but not essential.

---

## Reference Card

```bash
# Cluster (kind)
kind get clusters
kind create cluster --config ~/lab3/kind-lab3.yaml
kind delete cluster --name lab3
kind load docker-image <img> --name lab3
kind export kubeconfig --name lab3

# Context / namespace
kubectl config get-contexts
kubectl config use-context kind-lab3
kubectl config set-context --current --namespace=<ns>
kubectl config view --minify

# Inspect
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get all
kubectl get endpointslices -l kubernetes.io/service-name=<svc>
kubectl describe <kind> <name>
kubectl get events --sort-by=.lastTimestamp
kubectl api-resources
kubectl explain <kind>.<field>

# Create
kubectl run <name> --image=<img> --port=80
kubectl expose pod <name> --port=80 --target-port=80
kubectl apply -f <file|dir>
kubectl create <kind> <name> --dry-run=client -o yaml   # YAML generator

# Debug
kubectl logs <pod> [-c <container>] [--previous] [-f]
kubectl exec -it <pod> -- sh
kubectl run tmp --rm -it --image=busybox:1.36 --restart=Never -- sh
kubectl port-forward [--address 0.0.0.0] pod/<pod> 8080:80
kubectl get pods -w
kubectl get <kind> <name> -o yaml
kubectl get pods --v=8

# Lifecycle
kubectl scale deployment <name> --replicas=N
kubectl rollout status|history|undo deployment/<name>
kubectl cordon|uncordon|drain <node>
kubectl delete -f <file>
kubectl delete <kind> --all -n <ns>
```

---

## Lab Execution

*(To be documented as the lab is run.)*

---

## Documented Issues

*(None recorded yet.)*
