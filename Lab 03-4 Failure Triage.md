# Lab 3.4 — Failure Triage

**Detailed walkthrough. Builds on the `lab3` KinD cluster and the five-service application completed in Sub-labs 3.1 to 3.3.**

---

## Objective

Learn to diagnose a broken Kubernetes workload from its symptoms, using a fixed sequence of commands, without guessing.

You now have nine network hops between a web browser and a database row. Any one of them can fail, and many of those failures look identical from the outside. The website is down, or a page shows an error, and that single symptom can have at least nine different causes with nine different fixes.

The goal of this sub-lab is not to memorise fixes. It is to build a **procedure**: a fixed order of commands you run before you form any theory about what is wrong. People who are good at Kubernetes are not people who recognise every error message. They are people who follow the same short sequence every time and let the cluster tell them where the problem is.

**This sub-lab is different from the others.** Nothing new gets built. You will break the application nine times on purpose, diagnose each failure, and fix it. The output is a one-page reference table written in your own words.

---

## Why this comes before Sub-lab 3.5

Sub-lab 3.5 asks you to break things while the application is under load, and to measure failed requests during a deployment. That is much harder if you do not already have a diagnostic routine. Learn the routine on a quiet system first.

---

## Role tags

| Tag | Meaning |
|---|---|
| **[DEV]** | Application developer on Kubernetes. Diagnosing your own application. |
| **[PLAT]** | Platform or DevOps engineer. Diagnosing the cluster underneath the application. |
| **[SRE]** | Cluster administrator. One short section only. |

Most of this sub-lab is **[DEV]**. Two of the nine failures are **[PLAT]**, because they are caused by the cluster rather than by the application. Being able to tell those two apart from the other seven is one of the most useful outcomes here.

---

## How to use this guide

Same format as the previous sub-labs:

- **Run** — the exact commands.
- **Expect** — what a correct result looks like.
- **Why it matters** — the idea you should take away.

Sections marked **[Deep dive]** are optional for the checklist but useful in practice.

**One extra instruction for this sub-lab.** Each failure section has a box labelled **Try this yourself first**. Stop reading at that box, run the triage loop, and write down what you think is wrong. Then read the walkthrough. The value of this sub-lab comes from the attempt, not from the explanation. If you read the answer first, you will finish the sub-lab having learned very little.

**Convention:** `$` means a command on the Ubuntu host over SSH. `PS>` means a command on your Windows workstation.

---

# Step 0 — Preparation

## 0.1 — Confirm the starting state

```bash
kubectl config current-context                    # kind-lab3
kubectl config view --minify | grep namespace:    # multi-service-app
kubectl get nodes
kubectl get pods -o wide
kubectl get svc
kubectl get httproute
kubectl get pods -n traefik
```

**Expect:** three nodes `Ready`. Four Pods (`postgres`, `python-api`, `node-api`, `react-frontend`), all `1/1 Running` with `RESTARTS 0`. Four Services. One `HTTPRoute` named `msa-route`. One Traefik Pod running in the `traefik` namespace.

If anything is already broken, fix it before continuing. This sub-lab depends on being able to compare a broken state against a known good one.

## 0.2 — Record a baseline

You cannot recognise abnormal output if you have never looked carefully at normal output. Save the healthy state to a file so you can compare against it later.

```bash
mkdir -p ~/lab3/triage
cd ~/lab3/triage

{
  echo "===== BASELINE $(date) ====="
  echo "--- pods ---";            kubectl get pods -o wide
  echo "--- deployments ---";     kubectl get deploy
  echo "--- services ---";        kubectl get svc
  echo "--- endpointslices ---";  kubectl get endpointslices
  echo "--- pvc ---";             kubectl get pvc
  echo "--- events (last 20) ---"; kubectl get events --sort-by=.lastTimestamp | tail -20
} > baseline.txt

cat baseline.txt
```

Also record the working HTTP responses:

```bash
{
  for p in / /api/py/health /api/py/api/db /api/node/health /api/node/api/db; do
    printf '%-24s ' "$p"
    curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -m 5 "http://localhost:30080$p"
  done
} > baseline-http.txt

cat baseline-http.txt
```

**Expect:** `HTTP 200` on all five paths.

**Why it matters:** the first question in any real incident is "what changed?" You cannot answer that without a record of the previous state. In a real environment this record comes from monitoring and from version control. Here it comes from a text file, but the habit is the same.

## 0.3 — Create a working directory for broken manifests

```bash
mkdir -p ~/lab3/broken
ls -l ~/lab3/msa/
```

You will write nine broken manifests into `~/lab3/broken/`. Keep them after the sub-lab. Sub-lab 3.5 reuses two of them, and they are useful for testing yourself again in a few weeks.

## 0.4 — Pre-load the debugging container image

You will use `nicolaka/netshoot`, a container image that contains the network tools your application images do not have. Load it into the cluster now so that later steps do not stall while an image downloads.

```bash
docker pull nicolaka/netshoot:latest
kind load docker-image nicolaka/netshoot:latest --name lab3

for n in lab3-control-plane lab3-worker lab3-worker2; do
  docker exec "$n" crictl images | grep netshoot || echo "$n MISSING"
done
```

**Expect:** present on all three nodes.

## 0.5 — Optional: the readiness toggle endpoint

The master plan lists a small application change: an endpoint such as `/admin/ready` that flips an in-memory flag so the health endpoint starts returning a failure. This makes failure number 8 easier to observe.

Check whether you have added it:

```bash
curl -sS -X POST http://localhost:30080/api/node/admin/ready 2>&1 | head -3
```

If it is not there, that is fine. Failure number 8 has an alternative method that works without it. Add the endpoint later if you want, before Sub-lab 3.5.

---

# Step 1 — The triage loop **[DEV]**

Before breaking anything, learn the sequence and practise it on a **healthy** Pod. This matters. If you have only ever read `kubectl describe` output for a broken Pod, you will not know which parts of it are normal.

## 1.1 — The five steps, in order

```
1. kubectl get pods
      What state is it in? The state tells you which layer failed.

2. kubectl describe pod <name>
      Read the Events section at the bottom, from the bottom upwards.
      Also read Last State, Reason, and Exit Code.

3. kubectl logs <name>
      Add --previous if the container has restarted.
      Add -c <name> for a specific container or init container.

4. kubectl events --for pod/<name>
      Everything the cluster recorded about this object, in time order.

5. kubectl exec  or  kubectl debug
      Only now, once you have a theory you want to test.
```

**Why the order matters.** Steps 1 to 4 are read-only, take a few seconds each, and cannot make anything worse. Step 5 requires a running container and is slow to work with.

Most people start at step 5. They open a shell inside the container and start looking around, which only works if the container is running in the first place. Three of the nine failures in this sub-lab have no running container at all, so step 5 is impossible for them. `describe` would have given the answer in one command.

## 1.2 — The five layers, and why the Pod state tells you which one failed

This is the most useful idea in the sub-lab. A Pod goes through a fixed sequence of stages on its way to serving traffic. Each stage is the responsibility of a different component. When a Pod is stuck, **the state name tells you which stage it did not get past**, and therefore which component to ask.

| Layer | Stage | Responsible component | Pod state when it fails |
|---|---|---|---|
| 1 | Object accepted and valid | kube-apiserver | the object is rejected; no Pod is created at all |
| 2 | Assigned to a node | kube-scheduler | `Pending` |
| 3 | Image obtained, container configured | kubelet, containerd | `ImagePullBackOff`, `ErrImagePull`, `CreateContainerConfigError`, `ContainerCreating` |
| 4 | Process started and stayed running | container runtime, your application | `CrashLoopBackOff`, `Error`, `OOMKilled` |
| 5 | Declared ready and receiving traffic | probes, endpoint controller, kube-proxy | `Running` but `0/1`, or `1/1 Running` and still unreachable |

Read that table twice. Almost every diagnosis in this sub-lab is an application of it.

Two consequences worth stating directly:

**A `Pending` Pod is never an application problem.** The application has not started. Nothing about your code, your image, or your configuration files can cause it. Reading application logs is pointless, because there are none.

**`1/1 Running` does not mean working.** It means the container process is alive and the readiness probe passed. It says nothing about whether traffic can reach it. Layer 5 failures all show a perfectly healthy-looking Pod.

## 1.3 — Practise on a healthy Pod

```bash
POD=$(kubectl get pod -l app=python-api -o jsonpath='{.items[0].metadata.name}')
echo "$POD"

kubectl get pod "$POD"
kubectl get pod "$POD" -o wide
```

**Expect:** `READY 1/1`, `STATUS Running`, `RESTARTS 0`.

Now read the full description:

```bash
kubectl describe pod "$POD"
```

That is roughly 80 lines. Learn where the useful parts are:

```bash
echo "=== Which node, and current phase ==="
kubectl describe pod "$POD" | sed -n '/^Node:/p;/^Status:/p'

echo "=== Init container result ==="
kubectl describe pod "$POD" | sed -n '/Init Containers:/,/^Containers:/p'

echo "=== Main container: state, restarts, limits ==="
kubectl describe pod "$POD" | sed -n '/^Containers:/,/^Conditions:/p'

echo "=== Conditions ==="
kubectl describe pod "$POD" | sed -n '/^Conditions:/,/^Volumes:/p'

echo "=== Events ==="
kubectl describe pod "$POD" | sed -n '/^Events:/,$p'
```

**Expect from a healthy Pod:**

- Init container: `State: Terminated`, `Reason: Completed`, `Exit Code: 0`
- Main container: `State: Running`, `Ready: True`, `Restart Count: 0`
- Conditions: `PodScheduled`, `Initialized`, `ContainersReady`, `Ready`, all `True`
- Events: `Scheduled`, `Pulled`, `Created`, `Started`. Four entries, no warnings.

**Two habits to build now:**

**Read Events from the bottom upwards.** They are printed oldest first. The most recent event is at the bottom, and the most recent event is almost always the one that matters.

**Look at Conditions before Events.** The four conditions map directly onto layers 2 to 5 in the table above. The first one that is `False` tells you which layer to investigate, in a single line.

## 1.4 — Practise reading logs

```bash
kubectl logs "$POD" --tail=20
kubectl logs "$POD" -c wait-for-postgres          # the init container, a separate log stream
kubectl logs "$POD" --since=5m
kubectl logs -l app=node-api --prefix --tail=5    # all Pods matching a label
```

**Why `-c` matters:** `kubectl logs` with no `-c` shows the **main** container. Your init container's logs are a completely separate stream and are invisible without `-c`. If an init container failed and you forget `-c`, you will see an empty result and conclude there are no logs, when in fact the answer is sitting right there.

**The most important flag in this entire sub-lab:**

```bash
kubectl logs "$POD" --previous
```

**Expect:** an error, because this container has not restarted, so there is no previous instance.

**Why it matters:** when a container crashes and restarts, `kubectl logs` shows you the **new** container, which has just started and has nothing interesting in it. The output you need, from the instance that actually failed, is only available with `--previous`. This one flag is the difference between diagnosing failure number 2 in thirty seconds and not being able to diagnose it at all.

## 1.5 — Events

```bash
kubectl events --for pod/"$POD"
kubectl get events --sort-by=.lastTimestamp | tail -20
kubectl get events --field-selector type=Warning
```

**Two things to know about events.**

They **expire**, by default after one hour. An event is not a log entry. If a Pod failed overnight and you look at it in the morning, the events explaining why may already be gone. This is one reason clusters ship events to a permanent store.

They are attached to **objects**, and not always to the object you are looking at. A ReplicaSet that cannot create a Pod records the event on the **ReplicaSet**, not on a Pod, because no Pod exists. If you only ever look at Pod events, you will miss these completely.

## 1.6 — Exit codes you should recognise

When a container stops, `describe` shows an exit code. A small number of values cover most cases:

| Exit code | Meaning |
|---|---|
| `0` | Finished successfully. Normal for an init container or a Job; a problem for a long-running service. |
| `1` | General application error. Read the logs. |
| `2` | Usually a command line or shell usage error. |
| `126` | The command was found but could not be executed, often a permissions problem. |
| `127` | Command not found. Usually a typo in `command`, or a tool missing from a slim image. |
| `137` | Killed by SIGKILL. This is `128 + 9`. **Almost always out of memory.** |
| `139` | Segmentation fault. This is `128 + 11`. |
| `143` | Terminated by SIGTERM. This is `128 + 15`. Normal during a shutdown. |

**The pattern:** any exit code above 128 means the process was stopped by a signal, and the signal number is the code minus 128. `137` and `143` are the two you will see most often, and they mean very different things. `143` is usually normal. `137` usually means you set a memory limit too low.

## 1.7 — Restart backoff

```bash
kubectl get pod "$POD" -o jsonpath='{.status.containerStatuses[0].restartCount}'; echo
```

When a container keeps failing, Kubernetes does not restart it immediately every time. It waits, and the wait doubles: 10 seconds, 20, 40, 80, 160, 300, then 300 seconds from then on.

**Why this matters in practice:** a Pod stuck in `CrashLoopBackOff` may take up to five minutes to try again. If you fix the underlying problem, such as bringing a database back online, the Pod may sit there doing nothing for several minutes before it retries. The system is not broken and you do not need to wait. `kubectl rollout restart deployment/<name>` resets the backoff timer immediately.

This is also the reason the init container pattern from Sub-lab 3.2 is worth using. An init container that waits in a loop retries every two seconds. A crashing main container retries every five minutes.

---

# Step 2 — The active tools **[DEV]**

Three tools for step 5 of the loop. Practise them on the healthy application now, so that when you need them you are not learning the syntax at the same time as diagnosing a problem.

## 2.1 — `kubectl exec`

Runs a command inside an existing container.

```bash
kubectl exec "$POD" -- env | grep -E '^DB_' | sort
kubectl exec "$POD" -- ls -la /
kubectl exec -it "$POD" -- sh          # interactive shell; type exit to leave
```

**The limitation:** `exec` can only run programs that are already inside the image. In Sub-lab 3.2 §11 you hit this directly. The Python image had no `nslookup`, so you had to fall back on `python3 -c "import socket"`. That worked because Python was present. In a truly minimal image, nothing is present, and `exec` gives you almost nothing.

## 2.2 — `kubectl debug`

This solves the problem `exec` cannot. It attaches an **additional** container to a running Pod, sharing the same network namespace, so a container full of network tools appears inside your Pod.

```bash
kubectl debug -it "$POD" --image=nicolaka/netshoot:latest --target=python-api -- bash
```

Inside that shell:

```bash
# You are in python-api's network namespace, with real tools
nslookup postgres-db
nslookup python-api
dig +short postgres-db.multi-service-app.svc.cluster.local
curl -sS -o /dev/null -w '%{http_code}\n' http://localhost:8001/health
nc -zv postgres-db 5432
ss -tulpn
ip addr
cat /etc/resolv.conf
exit
```

**Expect:** DNS resolves to a ClusterIP in `10.96.0.0/16`, the local health endpoint returns 200, and the Postgres port is open.

**Why it matters:** compare this to the workaround in Sub-lab 3.2 §11. Every tool you wished you had is now available, inside the Pod you care about, with that Pod's exact network view, without changing the image and without adding debugging tools to a production image.

Two details:

`--target=python-api` shares the **process** namespace with that container as well, so you can also see its processes. Without `--target`, you share only the network namespace.

The debug container is added to the Pod and stays there until the Pod is deleted. Clean up:

```bash
kubectl get pod "$POD" -o jsonpath='{.spec.ephemeralContainers[*].name}'; echo
```

You cannot remove an ephemeral container from a running Pod. Deleting the Pod removes it, and the Deployment creates a replacement. This is acceptable in a lab. In production, be aware that debugging leaves a trace on the Pod.

## 2.3 — `kubectl debug node` **[PLAT]**

The same idea for a node instead of a Pod.

```bash
kubectl debug node/lab3-worker -it --image=busybox:1.36 -- sh
```

Inside:

```bash
ls /host/var/log
cat /host/etc/os-release
exit
```

The node's filesystem is mounted under `/host`. This creates a Pod on that node with elevated access, which is why the permission to do it is tightly controlled in real clusters.

```bash
kubectl get pods | grep node-debugger
kubectl delete pod -l '!app' --field-selector status.phase=Running 2>/dev/null || true
# or simply delete the node-debugger Pod by name
```

## 2.4 — A disposable client Pod

You have used this pattern already. It is worth naming, because you will use it constantly.

```bash
kubectl run tmp --rm -it --image=nicolaka/netshoot:latest --restart=Never -- bash
```

`--rm` deletes the Pod on exit, `-it` attaches your terminal, `--restart=Never` makes it a plain Pod rather than a Deployment. This gives you a clean network client inside the cluster with no relation to your application. It is the right tool for testing whether a **Service** works, because it tests from the outside, exactly as a real client would.

## 2.5 — Output formatting that saves time

```bash
# One field
kubectl get pod "$POD" -o jsonpath='{.status.podIP}'; echo

# Chosen columns across many objects
kubectl get pods -o custom-columns=\
'NAME:.metadata.name,STATE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName'

# Restart counts across the namespace, highest first
kubectl get pods -o json | python3 -c "
import sys, json
d = json.load(sys.stdin)
rows = []
for p in d['items']:
    for c in p['status'].get('containerStatuses', []):
        rows.append((c['restartCount'], p['metadata']['name'], c['name']))
for r in sorted(rows, reverse=True):
    print(f'{r[0]:>4}  {r[1]}  ({r[2]})')
"
```

Save the second one as an alias. It is the fastest way to see the state of a namespace at a glance:

```bash
echo "alias kps=\"kubectl get pods -o custom-columns='NAME:.metadata.name,STATE:.status.phase,READY:.status.containerStatuses[0].ready,RESTARTS:.status.containerStatuses[0].restartCount,NODE:.spec.nodeName'\"" >> ~/.bashrc
source ~/.bashrc
kps
```

---

# Step 3 — Failure 1: `ImagePullBackOff` **[DEV]**

**Layer 3. The image could not be obtained.**

## 3.1 — Break it

```bash
cp ~/lab3/msa/10-node-api-deployment.yaml ~/lab3/broken/01-image-tag.yaml
sed -i 's|image: node-api:0.1.0|image: node-api:0.2.0|' ~/lab3/broken/01-image-tag.yaml
grep -n 'image: node-api' ~/lab3/broken/01-image-tag.yaml

kubectl apply -f ~/lab3/broken/01-image-tag.yaml
```

## 3.2 — Symptom

```bash
kubectl get pods -l app=node-api -w
# press Ctrl-C after about 60 seconds
```

**Expect:** a new Pod appears, sits at `0/1` with `ErrImagePull`, then changes to `ImagePullBackOff`. The old Pod stays `1/1 Running`.

> ### Try this yourself first
> Run the triage loop before reading on. Specifically:
> 1. What state is the Pod in, and which layer does that point to?
> 2. What does `describe` say in the Events section?
> 3. Is `kubectl logs` any use here? Try it and note what happens.
> 4. Why is the application still working?

## 3.3 — The diagnosis

```bash
BAD=$(kubectl get pods -l app=node-api --field-selector status.phase=Pending -o jsonpath='{.items[0].metadata.name}')
echo "$BAD"

kubectl describe pod "$BAD" | sed -n '/^Events:/,$p'
```

**Expect** something similar to:

```
Warning  Failed     kubelet  Failed to pull image "node-api:0.2.0":
                             failed to pull and unpack image ...
                             failed to resolve reference "docker.io/library/node-api:0.2.0":
                             pull access denied, repository does not exist or may require authorization
Warning  Failed     kubelet  Error: ErrImagePull
Normal   BackOff    kubelet  Back-off pulling image "node-api:0.2.0"
Warning  Failed     kubelet  Error: ImagePullBackOff
```

Now try the logs:

```bash
kubectl logs "$BAD"
```

**Expect:** an error stating the container is waiting to start. **There are no logs, because there is no container.** This is the point of the layer table. A layer 3 failure means the application never ran, so application logs cannot exist.

Note the important detail in the error text: `docker.io/library/node-api`. Kubernetes could not find the image locally, so it assumed the image came from Docker Hub and tried to download it from there.

## 3.4 — Confirm the specific cause

```bash
# Is the tag actually in the cluster's image store?
docker exec lab3-worker  crictl images | grep node-api
docker exec lab3-worker2 crictl images | grep node-api

# What does the Deployment ask for?
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

**Expect:** the store has `0.1.0`. The Deployment asks for `0.2.0`.

## 3.5 — Why it matters

`ImagePullBackOff` has a small set of causes and they are easy to separate:

| Cause | How to confirm |
|---|---|
| Typo in the image name or tag | Compare against the registry, or `crictl images` on a node |
| The tag genuinely does not exist | Same |
| Private registry, no credentials | The error mentions authorization; check `imagePullSecrets` |
| Registry unreachable | The error mentions a timeout or DNS failure |
| **KinD only: you forgot `kind load`** | `crictl images` on the nodes shows nothing |

The last one is specific to your setup and you should expect to hit it for real. Building an image with `docker build` does **not** put it in the cluster. This is the two-separate-image-stores point from Sub-lab 3.2 §1.3 and again in 3.3 §1.1.

There is a second version of this failure that is worth understanding, because it is more confusing.

## 3.6 — [Deep dive] The `imagePullPolicy` trap

```bash
kubectl delete -f ~/lab3/broken/01-image-tag.yaml >/dev/null 2>&1
kubectl apply  -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=90s

# Correct tag this time, but force Kubernetes to always download
cp ~/lab3/msa/10-node-api-deployment.yaml ~/lab3/broken/01b-pull-policy.yaml
sed -i 's|imagePullPolicy: IfNotPresent|imagePullPolicy: Always|' ~/lab3/broken/01b-pull-policy.yaml
kubectl apply -f ~/lab3/broken/01b-pull-policy.yaml

sleep 30
kubectl get pods -l app=node-api
kubectl describe pod -l app=node-api | grep -A5 'Failed to pull' | head -10
```

**Expect:** `ImagePullBackOff` again, even though the tag is correct and the image is definitely present on every node.

**Why:** `imagePullPolicy: Always` instructs the kubelet to contact the registry every time, regardless of what is already stored locally. Your image was never in a registry. It was copied directly into each node by `kind load`. So the download fails, and the local copy is ignored.

**Why this matters beyond KinD.** This is the same error message as failure 1 with an entirely different cause. The tag is right, the image is present, and it still fails. The only way to tell the two apart is to check both the image store and the pull policy.

There is also a rule that catches people out: **if your image tag is `latest`, the pull policy defaults to `Always`.** So a locally built `myapp:latest` in KinD fails, while `myapp:0.1.0` works, purely because of the tag name. This is one of several good reasons not to use `latest`.

## 3.7 — Fix

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=90s
kubectl get pods -l app=node-api
curl -sS http://localhost:30080/api/node/health; echo
```

---

# Step 4 — Failure 2: `CrashLoopBackOff` **[DEV]**

**Layer 4. The container started and then stopped.**

## 4.1 — Break it

```bash
cp ~/lab3/msa/10-node-api-deployment.yaml ~/lab3/broken/02-crashloop.yaml

python3 - <<'EOF'
import re
p = '/root/lab3/broken/02-crashloop.yaml'
import os
p = os.path.expanduser('~/lab3/broken/02-crashloop.yaml')
s = open(p).read()
s = s.replace(
  "          image: node-api:0.1.0\n",
  "          image: node-api:0.1.0\n"
  "          command: [\"sh\", \"-c\", \"echo 'starting up'; sleep 2; "
  "echo 'FATAL: cannot read configuration file /etc/app/config.json' >&2; exit 1\"]\n"
)
open(p,'w').write(s)
EOF

grep -n -A2 'image: node-api' ~/lab3/broken/02-crashloop.yaml
kubectl apply -f ~/lab3/broken/02-crashloop.yaml
```

The fake error message is deliberate. Real crash loops usually come with a message that names the actual problem, and reading that message is the whole task.

## 4.2 — Symptom

```bash
kubectl get pods -l app=node-api -w
# Ctrl-C after about 90 seconds
```

**Expect:** the Pod cycles through `Running`, then `Error`, then `CrashLoopBackOff`, and the `RESTARTS` count climbs. Watch the gaps between restarts grow, as described in §1.7.

> ### Try this yourself first
> 1. `kubectl logs` on the Pod. What do you see, and why is it not helpful?
> 2. Find the flag that makes it helpful.
> 3. What exit code does `describe` report, and what does that number mean?
> 4. How is this different from failure 1, given both show a Pod that will not start?

## 4.3 — The diagnosis

```bash
BAD=$(kubectl get pods -l app=node-api -o jsonpath='{.items[0].metadata.name}')

echo "=== plain logs ==="
kubectl logs "$BAD"
```

**Expect:** either nothing, or a line or two from a container that has only just started. The output from the instance that failed is not here.

```bash
echo "=== previous instance ==="
kubectl logs "$BAD" --previous
```

**Expect:**

```
starting up
FATAL: cannot read configuration file /etc/app/config.json
```

There is the answer.

```bash
kubectl describe pod "$BAD" | sed -n '/^Containers:/,/^Conditions:/p'
```

**Expect** a block similar to:

```
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       Error
      Exit Code:    1
      Started:      ...
      Finished:     ...
    Restart Count:  5
```

Read those fields in this order:

- **`State`** is where it is now. `Waiting` with `CrashLoopBackOff` means Kubernetes is waiting before the next attempt.
- **`Last State`** is what happened on the previous attempt. This is the important one.
- **`Exit Code: 1`** means a general application error. Not out of memory, which would be 137. Not a signal.
- **`Restart Count`** tells you how long this has been happening.

## 4.4 — Why it matters

**`--previous` is the whole lesson.** Without it, this failure is nearly impossible to diagnose. `kubectl logs` shows the current container, and the current container has not failed yet. The evidence lives in the previous one. Many people conclude "there are no logs" and start guessing.

**`CrashLoopBackOff` is a symptom, not a cause.** It only tells you the container keeps exiting. The reasons are unrelated to one another:

| Real cause | How you tell |
|---|---|
| Application error, such as bad configuration or a missing file | `--previous` logs, exit code 1 |
| Cannot reach a dependency, such as a database | `--previous` logs show a connection error |
| Out of memory | exit code **137**, `Reason: OOMKilled`. See failure 3. |
| Wrong `command` or `entrypoint` | exit code **127**, command not found |
| Liveness probe killing a healthy but slow application | logs look normal; events show `Unhealthy`. See §4.5. |
| The process finished normally, but is defined as a long-running service | exit code **0**, which is confusing the first time you see it |

That last one deserves a note. If a container exits with code 0 and the Pod's `restartPolicy` is `Always`, which is the default for a Deployment, Kubernetes restarts it, because a service is supposed to stay running. Success becomes a crash loop. This is common when someone containerises a script that does its job and exits.

## 4.5 — [Deep dive] The liveness probe crash loop

This is the version of failure 2 that is most often misdiagnosed, and you already read about it in the Sub-lab 3.2 retrofits. Now cause it.

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=90s

cp ~/lab3/msa/10-node-api-deployment.yaml ~/lab3/broken/02b-liveness.yaml

python3 - <<'EOF'
import os, re
p = os.path.expanduser('~/lab3/broken/02b-liveness.yaml')
s = open(p).read()
# remove the startupProbe block
s = re.sub(r'\n          startupProbe:\n(?:            .*\n|              .*\n)+', '\n', s)
# make liveness aggressive
s = s.replace(
  "          livenessProbe:\n"
  "            httpGet:\n"
  "              path: /health\n"
  "              port: http\n",
  "          livenessProbe:\n"
  "            httpGet:\n"
  "              path: /health\n"
  "              port: http\n"
  "            initialDelaySeconds: 1\n"
  "            timeoutSeconds: 1\n"
)
s = s.replace("            periodSeconds: 15\n            timeoutSeconds: 5\n            failureThreshold: 3",
              "            periodSeconds: 2\n            failureThreshold: 1")
open(p,'w').write(s)
EOF

grep -n -A8 'livenessProbe' ~/lab3/broken/02b-liveness.yaml
kubectl apply -f ~/lab3/broken/02b-liveness.yaml
sleep 45
kubectl get pods -l app=node-api
```

**Expect:** `CrashLoopBackOff` with a rising restart count, on an application that has nothing wrong with it.

```bash
BAD=$(kubectl get pods -l app=node-api -o jsonpath='{.items[0].metadata.name}')
kubectl logs "$BAD" --previous
kubectl describe pod "$BAD" | sed -n '/^Events:/,$p'
```

**Expect:** the logs look completely normal. The application starts up and reports no errors. The evidence is only in the events:

```
Warning  Unhealthy  kubelet  Liveness probe failed: Get "http://10.244.x.x:8002/health": context deadline exceeded
Normal   Killing    kubelet  Container node-api failed liveness probe, will be restarted
```

**Why it matters.** The application is healthy. Kubernetes is killing it. The probe fires one second after start, before the Node process has finished starting its HTTP listener, and `failureThreshold: 1` means a single failure is enough. The container is killed, restarted, and killed again. It never gets enough time to become healthy.

**This is the failure where reading the logs actively misleads you.** They look fine, because everything in the application is fine. Only the events name the cause. If you ever see a crash loop with clean logs, look at the events and check the probes before looking at anything else.

The fix is the `startupProbe` you added in the 3.2 retrofits. A startup probe suspends the liveness probe until the application has become healthy once, which removes the need to guess an `initialDelaySeconds` value.

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=90s
kubectl get pods -l app=node-api
```

---

# Step 5 — Failure 3: `OOMKilled` **[DEV]**

**Layer 4. The container exceeded its memory limit.**

> **Your database is safe.** You are about to set a memory limit on Postgres that is too low for it to start. The data is on the `postgres-pvc` PersistentVolumeClaim, which is a separate object from the Pod. Killing the container does not touch it. §5.5 verifies this after the fix.

## 5.1 — Break it

```bash
cp ~/lab3/msa/05-postgres-deployment.yaml ~/lab3/broken/03-oomkilled.yaml

python3 - <<'EOF'
import os
p = os.path.expanduser('~/lab3/broken/03-oomkilled.yaml')
s = open(p).read()
if 'resources:' in s:
    import re
    s = re.sub(r'\n          resources:\n(?:            .*\n|              .*\n)+', '\n', s)
s = s.replace(
  "          volumeMounts:\n",
  "          resources:\n"
  "            requests:\n"
  "              cpu: 50m\n"
  "              memory: 16Mi\n"
  "            limits:\n"
  "              memory: 32Mi\n"
  "          volumeMounts:\n"
)
open(p,'w').write(s)
EOF

grep -n -A7 'resources:' ~/lab3/broken/03-oomkilled.yaml
kubectl apply -f ~/lab3/broken/03-oomkilled.yaml
```

## 5.2 — Symptom

```bash
kubectl get pods -l app=postgres -w
# Ctrl-C after about 60 seconds
```

**Expect:** `CrashLoopBackOff`. On the surface this is identical to failure 2.

> ### Try this yourself first
> 1. Run `kubectl logs --previous`. Is the cause visible there?
> 2. What exit code does `describe` report? What is the reason?
> 3. This looks exactly like failure 2 in `kubectl get pods`. What single command distinguishes them?
> 4. Which of your other Pods are now unhealthy, and why?

## 5.3 — The diagnosis

```bash
BAD=$(kubectl get pods -l app=postgres -o jsonpath='{.items[0].metadata.name}')

kubectl logs "$BAD" --previous
```

**Expect:** possibly a few normal startup lines from Postgres, and then nothing. **No error message.** The process did not fail. It was killed from outside, with no opportunity to log anything.

```bash
kubectl describe pod "$BAD" | sed -n '/^Containers:/,/^Conditions:/p'
```

**Expect:**

```
    State:          Waiting
      Reason:       CrashLoopBackOff
    Last State:     Terminated
      Reason:       OOMKilled
      Exit Code:    137
    Restart Count:  4
    Limits:
      memory:  32Mi
    Requests:
      cpu:     50m
      memory:  16Mi
```

Two fields give you the answer immediately:

- **`Reason: OOMKilled`** states it directly.
- **`Exit Code: 137`**, which is `128 + 9`, meaning SIGKILL.

And `Limits: memory: 32Mi` right underneath tells you what to change.

## 5.4 — Why it matters

**The distinction between failures 2 and 3 is the point of this step.** In `kubectl get pods` they are the same. Both are `CrashLoopBackOff`. But:

| | Failure 2 (application error) | Failure 3 (out of memory) |
|---|---|---|
| `--previous` logs | contain a clear error | contain nothing useful |
| Exit code | `1` | `137` |
| `Reason` | `Error` | `OOMKilled` |
| Where to look | application code or configuration | the `resources.limits` in the manifest |
| Who fixes it | the developer | the developer or the platform team |

**The reason `--previous` is empty is worth understanding.** SIGKILL cannot be caught, blocked, or handled. The kernel stops the process immediately. There is no shutdown routine and no final log line. A container that dies silently, with no error anywhere, is characteristic of being killed rather than failing.

**Note what else broke.** Look at the whole namespace:

```bash
kps
kubectl get endpointslices
curl -sS http://localhost:30080/api/py/api/db; echo
```

**Expect:** `python-api` and `node-api` are now unhealthy or restarting, because their database has gone. `/api/db` fails.

This is a **cascading failure**, and it is the situation you will actually face. Four Pods look wrong, and only one of them has a real problem. Diagnosing this means finding the earliest failure in the chain, not the loudest one.

The events are ordered by time and are the fastest way to find the origin:

```bash
kubectl get events --sort-by=.lastTimestamp | tail -30
```

Look for the **oldest** warning. That is usually the cause. Everything after it is a consequence.

## 5.5 — Fix and verify the data survived

```bash
kubectl apply -f ~/lab3/msa/05-postgres-deployment.yaml
kubectl rollout status deployment/postgres --timeout=180s

kubectl get pvc
kubectl rollout restart deployment/python-api deployment/node-api
kubectl rollout status deployment/python-api --timeout=120s
kubectl rollout status deployment/node-api  --timeout=120s

curl -sS http://localhost:30080/api/py/api/db; echo
```

**Expect:** the PVC is still `Bound`, and the heartbeat count continues from where it was rather than restarting at zero.

**Why it matters:** you just destroyed the database container repeatedly and lost no data. That is exactly what the PersistentVolumeClaim is for, and it is the same lesson as Sub-lab 3.2 §12.4, now demonstrated by accident rather than on purpose. Container lifetime and data lifetime are separate concerns.

---

# Step 6 — Failure 4: `Pending`, unschedulable **[PLAT]**

**Layer 2. No node can accept this Pod.**

## 6.1 — Break it

```bash
cp ~/lab3/msa/10-node-api-deployment.yaml ~/lab3/broken/04-unschedulable.yaml
sed -i 's/              cpu: 50m/              cpu: 8/' ~/lab3/broken/04-unschedulable.yaml
grep -n -A5 'requests:' ~/lab3/broken/04-unschedulable.yaml

kubectl apply -f ~/lab3/broken/04-unschedulable.yaml
sleep 10
kubectl get pods -l app=node-api
```

## 6.2 — Symptom

**Expect:** a new Pod stuck at `0/1 Pending`, with `AGE` increasing and nothing else changing. No restarts. No error status. The old Pod stays `1/1 Running`.

> ### Try this yourself first
> 1. Is `kubectl logs` useful? Try it and explain why not.
> 2. What does `describe` say in Events?
> 3. Check `kubectl top nodes` and `kubectl describe node`. Is the cluster actually busy?
> 4. Which of the five layers has failed, and which component is responsible?

## 6.3 — The diagnosis

```bash
BAD=$(kubectl get pods -l app=node-api --field-selector status.phase=Pending -o jsonpath='{.items[0].metadata.name}')

kubectl logs "$BAD"
```

**Expect:** an error stating the Pod has no assigned container to read from. **`Pending` means the Pod has not been placed on a node yet.** No node, no kubelet, no container, no logs. There is nothing to read.

```bash
kubectl describe pod "$BAD" | sed -n '/^Events:/,$p'
```

**Expect:**

```
Warning  FailedScheduling  default-scheduler
  0/3 nodes are available: 1 node(s) had untolerated taint
  {node-role.kubernetes.io/control-plane: }, 2 Insufficient cpu.
  preemption: 0/3 nodes are available: ...
```

**Read that message carefully. It is one of the most informative messages Kubernetes produces**, because it explains its decision for **every node**:

- `1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane: }` — the control-plane node refused the Pod. This is the taint you found in Sub-lab 3.1 §2.6, appearing again in a real diagnosis.
- `2 Insufficient cpu` — both workers refused because of CPU.

Three nodes, two distinct reasons, both stated.

## 6.4 — Confirm the arithmetic

```bash
kubectl describe node lab3-worker | sed -n '/Allocatable:/,/Allocated resources:/p'
kubectl describe node lab3-worker | sed -n '/Allocated resources:/,/Events:/p'
```

**Expect:** allocatable CPU of a few cores, and a table of allocated requests well under the limit.

Now the important observation:

```bash
kubectl top nodes
```

**Expect:** actual CPU usage in the low single-digit percentages.

**The node is nearly idle and the Pod cannot be scheduled.**

**Why:** the scheduler does not look at usage at all. It adds up the `requests` of every Pod already assigned to a node and compares that sum against the node's allocatable capacity. Your Pod asked for 8 CPUs. No worker has 8 CPUs of unreserved request capacity, so no worker is eligible.

**`requests` is a reservation, not a measurement.** The scheduler performs arithmetic on numbers you typed into a YAML file. It has no knowledge of what your application actually consumes. Sub-lab 3.6 covers this in depth, along with correcting your request values based on real measurements.

## 6.5 — Why it matters

`Pending` has a short list of causes, and `describe` names which one every time:

| Cause | Message contains |
|---|---|
| Not enough CPU or memory requested capacity | `Insufficient cpu` / `Insufficient memory` |
| A taint with no matching toleration | `untolerated taint` |
| `nodeSelector` matches no node | `node(s) didn't match Pod's node affinity/selector` |
| Anti-affinity cannot be satisfied | `node(s) didn't satisfy existing pods anti-affinity rules` |
| A volume cannot be attached in that zone | `node(s) had volume node affinity conflict` |
| **The PVC is not bound** | `pod has unbound immediate PersistentVolumeClaims`. See failure 9. |
| No nodes are `Ready` | `0/3 nodes are available` with no per-node reason |

**The single most useful thing to remember: a `Pending` Pod is a scheduling problem, and scheduling problems are always explained in `kubectl describe pod`.** You never have to guess. You do have to read the message, which is long and easy to skim past.

## 6.6 — Fix

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=90s
kps
```

---

# Step 7 — Failure 5: `CreateContainerConfigError` **[DEV]**

**Layer 3. The Pod is on a node, but the container cannot be configured.**

## 7.1 — Break it

```bash
cp ~/lab3/msa/10-node-api-deployment.yaml ~/lab3/broken/05-missing-secret-key.yaml
sed -i 's/                  key: password/                  key: db_password/' \
  ~/lab3/broken/05-missing-secret-key.yaml
grep -n -B4 'key: db_password' ~/lab3/broken/05-missing-secret-key.yaml

kubectl apply -f ~/lab3/broken/05-missing-secret-key.yaml
sleep 15
kubectl get pods -l app=node-api
```

This is a realistic mistake. The Secret exists. The reference to it is correct. Only the key name inside it is wrong, because someone assumed a different naming convention.

## 7.2 — Symptom

**Expect:** `0/1 CreateContainerConfigError`.

> ### Try this yourself first
> 1. Try `kubectl logs`, `kubectl logs --previous`, and `kubectl exec`. All three fail. Explain why.
> 2. Which command does work?
> 3. How is this state different from `Pending` and from `CrashLoopBackOff`?

## 7.3 — The diagnosis

```bash
BAD=$(kubectl get pods -l app=node-api -o jsonpath='{.items[0].metadata.name}')

kubectl logs "$BAD"
kubectl logs "$BAD" --previous
kubectl exec "$BAD" -- env 2>&1 | head -3
```

**Expect:** all three fail. This state is a difficult one, because you have almost no tools.

**Why:** the Pod is scheduled, so it is not `Pending`. The image is pulled. But the kubelet cannot assemble the container's configuration, so **no container was ever created**. There is no process, no filesystem, and no log stream. `logs`, `--previous`, and `exec` all require a container that exists.

`describe` is your only option:

```bash
kubectl describe pod "$BAD" | sed -n '/^Events:/,$p'
```

**Expect:**

```
Warning  Failed  kubelet  Error: couldn't find key db_password in Secret multi-service-app/db-credentials
```

That names the missing key, the Secret, and the namespace.

## 7.4 — Confirm

```bash
kubectl get secret db-credentials -o jsonpath='{.data}' | python3 -m json.tool
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].env}' | python3 -m json.tool
```

**Expect:** the Secret has `username` and `password`. The Deployment asks for `db_password`.

## 7.5 — Why it matters

**This state exists in the narrow window between "scheduled" and "started", and almost none of your usual tools work in it.** Recognising the state name is what tells you to go straight to `describe` instead of spending five minutes trying to read logs that cannot exist.

Causes, all of which produce the same state:

| Cause | Message contains |
|---|---|
| Missing key in a Secret | `couldn't find key X in Secret` |
| Missing key in a ConfigMap | `couldn't find key X in ConfigMap` |
| The Secret or ConfigMap does not exist at all | usually `CreateContainerConfigError` or `secret "X" not found` |
| Invalid `securityContext`, such as `runAsNonRoot` with a root image | `container has runAsNonRoot and image will run as root` |

That last one is the failure the Lab 3.3 notes warned you about for `node-api`. It appears in this same state, and now you know which command reveals it.

There is a related state worth naming: **`CreateContainerError`**, without `Config`. That means the container configuration was fine but the runtime could not start it, often because the `command` does not exist in the image. Similar name, different layer.

## 7.6 — Fix

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=90s
```

---

# Step 8 — Failure 6: wrong Service selector **[DEV]**

**Layer 5. Everything is healthy and no traffic arrives.**

You saw a version of this in Sub-lab 3.1 §4.5 with a toy nginx Pod. Now it happens in a five-service application behind a gateway, which is considerably harder to see.

## 8.1 — Break it

```bash
cp ~/lab3/msa/11-node-api-service.yaml ~/lab3/broken/06-bad-selector.yaml
sed -i 's/    app: node-api/    app: node-apo/' ~/lab3/broken/06-bad-selector.yaml
grep -n -A3 'selector:' ~/lab3/broken/06-bad-selector.yaml

kubectl apply -f ~/lab3/broken/06-bad-selector.yaml
```

## 8.2 — Symptom

```bash
kps
kubectl get svc node-api
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/api/node/health
curl -sS http://localhost:30080/api/node/health; echo
```

**Expect:** every Pod is `1/1 Running` with zero restarts. The Service exists and has a ClusterIP. There are no events and no warnings. And the request fails, most likely with a `503` or `502` from Traefik.

> ### Try this yourself first
> This is the hardest failure in the sub-lab, because everything looks correct.
> 1. `describe` the Pod. Anything wrong? `describe` the Service. Anything wrong?
> 2. Check the events. Anything at all?
> 3. There is one command that shows the problem instantly. Which one?
> 4. Confirm the Pod itself still works, by reaching it without going through the Service.

## 8.3 — The diagnosis

```bash
kubectl describe pod -l app=node-api | sed -n '/^Events:/,$p'
kubectl get events --sort-by=.lastTimestamp | tail -10
```

**Expect:** nothing relevant. **No error is recorded anywhere in the cluster.** From Kubernetes' point of view, nothing has gone wrong. You asked for a Service that selects Pods labelled `app=node-apo`, and it is faithfully providing a Service that selects zero Pods.

The single command that answers this:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=node-api
```

**Expect:** either no results, or a slice with an empty `ENDPOINTS` column.

Compare with a working Service:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=python-api
```

**Expect:** a populated `ENDPOINTS` column with a Pod IP.

Confirm the mismatch:

```bash
echo "Service selector:"
kubectl get svc node-api -o jsonpath='{.spec.selector}'; echo
echo "Pod labels:"
kubectl get pods -l app=node-api --show-labels
```

**Expect:** the selector says `app: node-apo`. The Pod says `app=node-api`.

Prove the Pod itself is fine by bypassing the Service completely:

```bash
POD_IP=$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].status.podIP}')
echo "$POD_IP"

kubectl run tmp --rm -it --image=nicolaka/netshoot:latest --restart=Never -- \
  curl -sS -m 5 "http://${POD_IP}:8002/health"; echo
```

**Expect:** the health endpoint responds. **The application is completely healthy. Only the routing to it is broken.**

## 8.4 — Why it matters

**Remember this as a rule:** *if a Service does not appear to work, run `kubectl get endpointslices` before anything else. Empty endpoints means your selector does not match your Pod labels.*

**Why this failure is so difficult without that rule.** There is no error message. There is no event. `describe pod` and `describe service` both look correct. The Pods are healthy. Every instinct sends you to look at the application, which is fine, or at the network, which is also fine.

**The underlying reason is the design principle from Sub-lab 3.1 §4.3.** A Service does not reference Pods by name. It holds a label query. A controller continuously looks for matching Pods and writes their addresses into an EndpointSlice. A query that matches nothing is not an error; it is a valid query with an empty result.

That indirection is what makes rolling updates, autoscaling, and self-healing work, because Pods can be replaced freely and the Service follows automatically. The cost is exactly this failure mode. It is a deliberate trade, and understanding it is why you should reach for `endpointslices` immediately rather than by elimination.

## 8.5 — Fix

```bash
kubectl apply -f ~/lab3/msa/11-node-api-service.yaml
kubectl get endpointslices -l kubernetes.io/service-name=node-api
curl -sS http://localhost:30080/api/node/health; echo
```

**Expect:** endpoints repopulate within about a second.

---

# Step 9 — Failure 7: wrong `targetPort` **[DEV]**

**Layer 5 again, and this is the one that is genuinely similar to failure 6. Spend time on the difference.**

## 9.1 — Break it

```bash
cp ~/lab3/msa/11-node-api-service.yaml ~/lab3/broken/07-bad-targetport.yaml
sed -i 's/      targetPort: http/      targetPort: 9999/' ~/lab3/broken/07-bad-targetport.yaml
grep -n -A5 'ports:' ~/lab3/broken/07-bad-targetport.yaml

kubectl apply -f ~/lab3/broken/07-bad-targetport.yaml
```

## 9.2 — Symptom

```bash
kps
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/api/node/health
```

**Expect:** identical to failure 6 from the outside. Healthy Pods, a working-looking Service, and a failing request.

> ### Try this yourself first
> 1. Run the command that solved failure 6. What is different this time?
> 2. Given that, where is the problem?
> 3. Which log would show it?

## 9.3 — The diagnosis

```bash
kubectl get endpointslices -l kubernetes.io/service-name=node-api -o yaml | \
  grep -E 'addresses|port:|name:' | head -20
```

**Expect:** the EndpointSlice is **populated**. It contains the Pod's IP address. But the port listed is `9999`.

**This is the whole distinction.** In failure 6 the endpoints were empty, so the Service had no idea which Pods to send traffic to. Here the Service knows exactly which Pod to use and is sending traffic to a port that nothing is listening on.

Confirm by testing both ports directly:

```bash
POD_IP=$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].status.podIP}')

kubectl run tmp --rm -it --image=nicolaka/netshoot:latest --restart=Never -- sh -c "
  echo '--- port 8002 (the real one) ---'
  curl -sS -m 3 -o /dev/null -w 'HTTP %{http_code}\n' http://${POD_IP}:8002/health || echo failed
  echo '--- port 9999 (what the Service targets) ---'
  curl -sS -m 3 -o /dev/null -w 'HTTP %{http_code}\n' http://${POD_IP}:9999/health || echo 'connection refused'
"
```

**Expect:** 200 on 8002, connection refused on 9999.

Look at what the proxy saw:

```bash
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=20 | grep -i 'node-api\|refused\|502\|503' | head
```

**Expect:** connection errors to `<pod-ip>:9999`.

## 9.4 — Compare failures 6 and 7 directly

This table is one of the most useful things in this sub-lab. Write it into your own reference.

| | Failure 6: bad selector | Failure 7: bad targetPort |
|---|---|---|
| Pod status | `1/1 Running` | `1/1 Running` |
| Service exists | yes | yes |
| **EndpointSlice** | **empty** | **populated** |
| Meaning | the Service does not know about any Pod | the Service knows the Pod, and the port is wrong |
| From a client | connection fails, or 503 from the proxy | connection refused, or 502 from the proxy |
| Cluster events | none | none |
| Where the evidence is | `get endpointslices` | `get endpointslices -o yaml`, and the proxy's logs |
| Fix | correct the `selector` | correct the `targetPort` |

**Why it matters:** the two failures look the same to a user and require different investigations. One command distinguishes them. If you only remember "check endpoints," you will solve failure 6 and be confused by failure 7. What you actually need to remember is "check endpoints, and read the port."

**Also note the value of named ports.** Your working manifest uses `targetPort: http`, referring to a name defined once in the Deployment. Using a name means the port number appears in exactly one place, so this failure becomes almost impossible to cause. That is why Sub-lab 3.2 §9.6 recommended it.

## 9.5 — Fix

```bash
kubectl apply -f ~/lab3/msa/11-node-api-service.yaml
curl -sS http://localhost:30080/api/node/health; echo
```

---

# Step 10 — Failure 8: readiness probe failing **[DEV]**

**Layer 5. The Pod is running and is deliberately excluded from traffic.**

## 10.1 — Break it

```bash
cp ~/lab3/msa/10-node-api-deployment.yaml ~/lab3/broken/08-bad-readiness.yaml

python3 - <<'EOF'
import os
p = os.path.expanduser('~/lab3/broken/08-bad-readiness.yaml')
s = open(p).read()
s = s.replace(
  "          readinessProbe:\n            httpGet:\n              path: /health\n",
  "          readinessProbe:\n            httpGet:\n              path: /healthz\n"
)
open(p,'w').write(s)
EOF

grep -n -A5 'readinessProbe' ~/lab3/broken/08-bad-readiness.yaml
kubectl apply -f ~/lab3/broken/08-bad-readiness.yaml
sleep 30
kubectl get pods -l app=node-api
```

`/healthz` instead of `/health`. This is a very common mistake, because different frameworks use different conventions.

## 10.2 — Symptom

**Expect:** a new Pod at `0/1 Running`, with `RESTARTS 0`, and the age increasing. It stays that way indefinitely. The old Pod stays `1/1 Running` and continues serving traffic.

> ### Try this yourself first
> 1. `0/1 Running` is a state you have not seen yet. What does each half of `0/1` mean?
> 2. Why is `RESTARTS` still 0, when failure 2's probe caused restarts?
> 3. Is the new Pod in the Service's endpoints? Check.
> 4. Is the application still serving users? Why?

## 10.3 — The diagnosis

```bash
BAD=$(kubectl get pods -l app=node-api --field-selector status.phase=Running \
  -o json | python3 -c "
import sys, json
for p in json.load(sys.stdin)['items']:
    cs = p['status'].get('containerStatuses', [{}])[0]
    if not cs.get('ready'):
        print(p['metadata']['name'])
        break
")
echo "$BAD"

kubectl describe pod "$BAD" | sed -n '/^Conditions:/,/^Volumes:/p'
```

**Expect:**

```
Conditions:
  Type              Status
  PodScheduled      True
  Initialized       True
  ContainersReady   False
  Ready             False
```

**Read this against the layer table from §1.2.** `PodScheduled` is true, so layer 2 passed. `Initialized` is true, so the init container completed and layer 3 passed. `ContainersReady` is false, so layer 5 is where it stopped. The conditions localise the failure in four lines.

```bash
kubectl describe pod "$BAD" | sed -n '/^Events:/,$p'
```

**Expect:**

```
Warning  Unhealthy  kubelet  Readiness probe failed: HTTP probe failed with statuscode: 404
```

The status code is the clue. A 404 means the server answered and does not have that path. That is very different from a connection refused or a timeout, which would mean the server is not listening at all.

```bash
kubectl logs "$BAD" --tail=20
```

**Expect:** normal startup messages, and repeated 404 entries for `/healthz` in the access log if the application logs requests.

Confirm which path exists:

```bash
kubectl debug -it "$BAD" --image=nicolaka/netshoot:latest --target=node-api -- sh -c '
  echo "--- /health ---";  curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8002/health
  echo "--- /healthz ---"; curl -sS -o /dev/null -w "%{http_code}\n" http://localhost:8002/healthz
'
```

**Expect:** 200 for `/health`, 404 for `/healthz`.

## 10.4 — The important part: the system protected you

```bash
kubectl get endpointslices -l kubernetes.io/service-name=node-api -o yaml | grep -E 'addresses|ready|conditions' -A2 | head -20
kps
curl -sS http://localhost:30080/api/node/health; echo
```

**Expect:** the unready Pod's address is either absent from the endpoints or marked as not ready. The application still works, because the old Pod is still serving.

**Why it matters.** This is the difference between readiness and liveness, seen in action:

| | readinessProbe | livenessProbe |
|---|---|---|
| Question it answers | "can I take traffic right now?" | "am I broken and unable to recover?" |
| Effect of failure | removed from Service endpoints | container killed and restarted |
| Restart count | unchanged | increases |
| Recovers when | the probe passes again | after a restart |
| This failure | `0/1 Running`, `RESTARTS 0`, forever | `CrashLoopBackOff`, restarts climbing |

A failing readiness probe is not a crash. It is Kubernetes doing exactly what you asked: keeping traffic away from a Pod that says it is not ready. **A Pod stuck at `0/1 Running` with no restarts is nearly always a readiness probe problem**, and that shape is worth memorising.

**Also note what this means for deployments.** The rollout has stalled. The new Pod never becomes ready, so the Deployment will not remove the old one. Your users are unaffected. This is the safety mechanism working, and it is why Sub-lab 3.5 asks you to recognise a stalled rollout as a good outcome rather than an incident.

```bash
kubectl rollout status deployment/node-api --timeout=20s
```

**Expect:** it reports waiting for the new replicas and then times out. The rollout is blocked, not failed.

## 10.5 — [Deep dive] Runtime readiness, if you added the toggle

If you added `/admin/ready` from §0.5:

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=90s
kubectl scale deployment node-api --replicas=2
kubectl rollout status deployment/node-api --timeout=90s

# In a second SSH session, watch the endpoints:
#   watch -n1 'kubectl get endpointslices -l kubernetes.io/service-name=node-api -o wide'

POD=$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- curl -sS -X POST http://localhost:8002/admin/ready
```

**Expect:** within a few seconds, that Pod goes to `0/1` and its address is removed from the endpoints, with no restart. Toggle it back and it returns.

**Why it matters:** this is exactly what a well-behaved application does during shutdown. It reports itself unready first, waits for the endpoint removal to take effect, and only then stops accepting connections. Sub-lab 3.5 builds on this directly.

```bash
kubectl scale deployment node-api --replicas=1
```

## 10.6 — Fix

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=90s
kps
```

---

# Step 11 — Failure 9: PVC `Pending` **[PLAT]**

**Layer 2, caused by an object that is not the Pod.**

## 11.1 — Break it

Use a separate, disposable PVC and Pod so that your working database is untouched.

```bash
cat > ~/lab3/broken/09-bad-storageclass.yaml <<'EOF'
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: broken-pvc
spec:
  accessModes:
    - ReadWriteOnce
  resources:
    requests:
      storage: 1Gi
  storageClassName: fast-ssd        # does not exist in this cluster
---
apiVersion: v1
kind: Pod
metadata:
  name: broken-storage-pod
  labels:
    app: broken-storage
spec:
  containers:
    - name: app
      image: busybox:1.36
      command: ["sh", "-c", "sleep 3600"]
      volumeMounts:
        - name: data
          mountPath: /data
  volumes:
    - name: data
      persistentVolumeClaim:
        claimName: broken-pvc
EOF

kubectl apply -f ~/lab3/broken/09-bad-storageclass.yaml
sleep 10
kubectl get pods -l app=broken-storage
kubectl get pvc
```

## 11.2 — Symptom

**Expect:** the Pod is `Pending` and the PVC is `Pending`. Two objects stuck.

> ### Try this yourself first
> 1. `describe` the **Pod**. Does the message point at the Pod itself?
> 2. Follow the pointer. Which object should you look at next?
> 3. `describe` the **PVC**. Now what is the message?
> 4. In Sub-lab 3.2 §5 you saw a PVC sit at `Pending` and that was **correct**. How do you tell the two situations apart?

## 11.3 — The diagnosis

```bash
kubectl describe pod broken-storage-pod | sed -n '/^Events:/,$p'
```

**Expect:**

```
Warning  FailedScheduling  default-scheduler
  0/3 nodes are available: pod has unbound immediate PersistentVolumeClaims
```

**Notice what the scheduler did here.** The message does not say the node is out of resources. It says the Pod has a claim that is not bound. **`describe pod` has pointed you at a different object.**

Follow it:

```bash
kubectl describe pvc broken-pvc | sed -n '/^Events:/,$p'
kubectl get pvc broken-pvc -o jsonpath='{.spec.storageClassName}'; echo
kubectl get storageclass
```

**Expect:** an event stating that the StorageClass `fast-ssd` was not found, and a StorageClass list containing only `standard`.

## 11.4 — The critical comparison with Sub-lab 3.2

In Sub-lab 3.2 §5 your `postgres-pvc` was `Pending` and the guide told you not to debug it. Compare the two directly.

```bash
echo "===== BROKEN pvc ====="
kubectl describe pvc broken-pvc | sed -n '/^Events:/,$p'

echo "===== HEALTHY pvc (from 3.2) ====="
kubectl describe pvc postgres-pvc | tail -8

echo "===== StorageClass binding mode ====="
kubectl get storageclass standard -o jsonpath='{.volumeBindingMode}'; echo
```

| | Sub-lab 3.2's `postgres-pvc` | This `broken-pvc` |
|---|---|---|
| Status | `Pending` | `Pending` |
| Event message | `waiting for first consumer to be created before binding` | `storageclass.storage.k8s.io "fast-ssd" not found` |
| Meaning | working as designed | genuinely broken |
| Resolves when | a Pod using it is scheduled | never, until you fix the manifest |

**Why it matters.** `Pending` on a PVC is normal in one case and a failure in another, and the status column cannot tell you which. **Only the event message can.** `WaitForFirstConsumer` binding means the storage system deliberately waits until it knows which node the Pod will run on, because the volume must be created in the right place. That behaviour exists in KinD's local-path provisioner and equally on AWS EBS, where a volume must be created in the correct availability zone.

This is the clearest example in the sub-lab of why "read the event message" beats "recognise the status."

## 11.5 — Clean up

```bash
kubectl delete -f ~/lab3/broken/09-bad-storageclass.yaml
kubectl get pvc
```

**Expect:** only `postgres-pvc` remains, `Bound`.

---

# Step 12 — Capstone: which layer is broken? **[DEV]** + **[PLAT]**

The nine failures above each had one cause and you knew which manifest you had edited. Real incidents do not work that way. You get a report that the website is broken, and your first job is to find out **which layer** to investigate.

## 12.1 — The localisation sequence

When something is wrong and you do not know where, work along the request path in order. Each check either passes, letting you move on, or fails, telling you to stop and investigate there.

```
1. Can the browser reach the entry point?      curl -o /dev/null -w '%{http_code}' http://host:30080/
      Connection refused  -> port mapping, NodePort, or Traefik itself
      Any HTTP response   -> the entry point is fine, continue

2. Does a route match?                          kubectl describe httproute msa-route
      404 from Traefik, Accepted: False -> routing layer
      Accepted and ResolvedRefs True     -> continue

3. Does the Service have endpoints?             kubectl get endpointslices
      Empty      -> selector or readiness problem
      Populated  -> continue, and check the port number

4. Are the Pods running and ready?              kubectl get pods
      Not Running -> layers 2, 3, or 4. Use describe.
      0/1 Running -> readiness probe
      1/1 Running -> continue

5. Does the application work when called directly?
                                                curl to the Pod IP from a netshoot Pod
      Fails    -> the application itself
      Succeeds -> the problem is between the Service and the Pod, likely the port

6. Can the application reach its dependencies?
                                                kubectl logs, then kubectl debug to test DNS and the port
```

Save that. It is the second half of this sub-lab's deliverable.

## 12.2 — Compound failure A

Apply this without reading it. Then diagnose it using the sequence above, and only afterwards look at the manifest.

```bash
cat > ~/lab3/broken/10-compound-a.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-api-config
  labels:
    app: node-api
data:
  DB_HOST: "postgres-database"
  DB_PORT: "5432"
  DB_NAME: "appdb"
  DB_SSL: "false"
  DB_CONNECT_TIMEOUT: "5"
EOF

kubectl apply -f ~/lab3/broken/10-compound-a.yaml
kubectl rollout restart deployment/node-api
sleep 40
```

> ### Diagnose before reading on
> Work through steps 1 to 6 of §12.1 and write down where it fails and why.

**What you should find.** The entry point responds. The route is accepted. Endpoints for `node-api` are empty or the Pod is not ready. The Pod is stuck at `Init:0/1`, not `Running`.

```bash
kubectl get pods -l app=node-api
kubectl logs -l app=node-api -c wait-for-postgres --tail=10
```

The init container is looping, waiting for a host called `postgres-database`, which does not exist. Confirm the DNS failure directly:

```bash
kubectl run tmp --rm -it --image=nicolaka/netshoot:latest --restart=Never -- sh -c '
  echo "--- postgres-db (real) ---";        nslookup postgres-db        2>&1 | tail -4
  echo "--- postgres-database (wrong) ---"; nslookup postgres-database  2>&1 | tail -4
'
```

**Why it matters.** This failure sits in the Pod's **configuration**, not in the Pod, the Service, or the route. And note where the init container placed it: the main container never started, so there are no application logs at all, and the Pod state is `Init:0/1` rather than `CrashLoopBackOff`. Without the init container, this would have been a crash loop with a five-minute backoff. Sub-lab 3.2 §9.3 predicted exactly this.

The Service name being load-bearing is the point Sub-lab 3.2 §7.1 made. Here is the consequence.

```bash
kubectl apply -f ~/lab3/msa/09-node-api-config.yaml
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=120s
curl -sS http://localhost:30080/api/node/api/db; echo
```

## 12.3 — Compound failure B

Two problems at once, which is realistic and much harder.

```bash
# Problem 1: Service port
kubectl patch svc python-api --type=json \
  -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9001}]'

# Problem 2: readiness path
kubectl patch deploy node-api --type=json \
  -p '[{"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/ready"}]'

sleep 40
```

> ### Diagnose before reading on
> Both APIs are now failing. Find both causes, and state which layer each one is in. They are not the same layer.

```bash
for p in / /api/py/health /api/node/health; do
  printf '%-20s ' "$p"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -m 5 "http://localhost:30080$p"
done

kps
kubectl get endpointslices
kubectl get endpointslices -l kubernetes.io/service-name=python-api -o yaml | grep -E 'port:|addresses'
kubectl describe pod -l app=node-api | sed -n '/^Conditions:/,/^Volumes:/p'
```

**What you should find:**

- **python-api:** Pod is `1/1 Running`, endpoints are **populated**, but the port is 9001. This is failure 7. The layer is the Service.
- **node-api:** Pod is `0/1 Running` with zero restarts, so its address is absent from the endpoints. This is failure 8. The layer is the readiness probe.

Two failures, two layers, one symptom from a browser. The frontend still loads, because that path is untouched, which makes the report from a user even more misleading: "the site works but the data is missing."

```bash
kubectl apply -f ~/lab3/msa/08-python-api-service.yaml
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=120s

for p in / /api/py/health /api/py/api/db /api/node/health /api/node/api/db; do
  printf '%-24s ' "$p"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -m 5 "http://localhost:30080$p"
done
```

## 12.4 — [Deep dive] Test yourself cold, later

The real skill is diagnosing a failure you did not create. Write a script that applies a random failure, then come back to it in a few days.

```bash
cat > ~/lab3/broken/random-break.sh <<'SH'
#!/usr/bin/env bash
# Applies one random failure. Does not tell you which.
# Restore with: ~/lab3/broken/restore.sh
set -euo pipefail
B="$HOME/lab3/broken"
FAILURES=(
  "01-image-tag.yaml"
  "02-crashloop.yaml"
  "02b-liveness.yaml"
  "03-oomkilled.yaml"
  "04-unschedulable.yaml"
  "05-missing-secret-key.yaml"
  "06-bad-selector.yaml"
  "07-bad-targetport.yaml"
  "08-bad-readiness.yaml"
  "10-compound-a.yaml"
)
PICK="${FAILURES[$RANDOM % ${#FAILURES[@]}]}"
kubectl apply -f "$B/$PICK" >/dev/null
echo "$PICK" > "$B/.last"
echo "A failure has been applied. Diagnose it."
echo "Reveal the answer with: cat $B/.last"
SH

cat > ~/lab3/broken/restore.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
M="$HOME/lab3/msa"
kubectl apply -f "$M/02-postgres-config.yaml"
kubectl apply -f "$M/03-python-api-config.yaml"
kubectl apply -f "$M/05-postgres-deployment.yaml"
kubectl apply -f "$M/06-postgres-service.yaml"
kubectl apply -f "$M/07-python-api-deployment.yaml"
kubectl apply -f "$M/08-python-api-service.yaml"
kubectl apply -f "$M/09-node-api-config.yaml"
kubectl apply -f "$M/10-node-api-deployment.yaml"
kubectl apply -f "$M/11-node-api-service.yaml"
kubectl apply -f "$M/12-react-frontend-deployment.yaml"
kubectl apply -f "$M/13-react-frontend-service.yaml"
kubectl apply -f "$M/16-httproute.yaml"
kubectl rollout restart deployment/postgres deployment/python-api deployment/node-api deployment/react-frontend
echo "Restoring. Check with: kubectl get pods -w"
SH

chmod +x ~/lab3/broken/random-break.sh ~/lab3/broken/restore.sh
```

Use it in a week. Diagnosing a failure you have forgotten the cause of is a completely different experience from diagnosing one you just created, and it is much closer to the real thing.

---

# Step 13 — The deliverable

This is the output of the sub-lab. Write it in your own words. Copying the template teaches you nothing; rewriting it is how the material becomes yours.

```bash
cat > ~/lab3/triage/TRIAGE.md <<'EOF'
# Kubernetes triage reference

## The loop (always this order)
1. kubectl get pods                    -> state names the layer
2. kubectl describe pod <name>         -> Conditions, then Events bottom-up
3. kubectl logs <name> [--previous]    -> --previous if it restarted
4. kubectl events --for pod/<name>     -> time-ordered, expires after ~1h
5. kubectl exec / kubectl debug        -> only with a theory to test

## The five layers
| Layer | Stage              | Owner              | Fails as |
|-------|--------------------|--------------------|----------|
| 1 | object valid           | apiserver          | rejected on apply |
| 2 | scheduled to a node    | scheduler          | Pending |
| 3 | image + config ready   | kubelet/containerd | ImagePullBackOff, CreateContainerConfigError |
| 4 | process running        | runtime + app      | CrashLoopBackOff, OOMKilled |
| 5 | ready + reachable      | probes, kube-proxy | 0/1 Running, or 1/1 and unreachable |

## State -> first command -> likely cause
| State | First command | Likely causes |
|-------|---------------|---------------|
| Pending | describe pod (Events) | insufficient requested capacity; taint; nodeSelector; unbound PVC |
| ImagePullBackOff | describe pod (Events) | bad tag; missing kind load; imagePullPolicy Always on a local image; no registry credentials |
| CreateContainerConfigError | describe pod ONLY | missing Secret/ConfigMap key; runAsNonRoot with a root image |
| CrashLoopBackOff | logs --previous | app error (exit 1); OOM (exit 137); bad command (exit 127); aggressive liveness probe (clean logs!) |
| 0/1 Running, 0 restarts | describe pod (Conditions + Events) | readiness probe failing. Rollout stalls; users unaffected. |
| 1/1 Running but unreachable | get endpointslices | EMPTY -> bad selector. POPULATED -> check the port number. |
| PVC Pending | describe pvc (Events) | "waiting for first consumer" = NORMAL. "storageclass not found" = broken. |

## Exit codes
0 finished (crash loop if restartPolicy Always) | 1 app error | 127 command not found
137 = 128+9 SIGKILL, almost always OOM | 143 = 128+15 SIGTERM, usually normal

## Rules I will not forget
- Pending is never an application problem. There are no logs.
- --previous or you are reading the wrong container.
- Empty endpoints = selector mismatch. Populated endpoints + failure = wrong port.
- Clean logs + a crash loop = look at the probes, not the code.
- CreateContainerConfigError: describe is the only tool that works.
- 0/1 Running with 0 restarts = readiness. 1/1 with restarts = liveness.
- Read the event message. The status alone cannot distinguish normal from broken.
- In a cascade, find the OLDEST warning, not the loudest.

## Localising an unknown failure
1. curl the entry point       -> refused = ports/proxy; any HTTP = continue
2. describe httproute         -> Accepted / ResolvedRefs
3. get endpointslices         -> empty vs populated, and the port
4. get pods                   -> not Running / 0-1 Running / 1-1 Running
5. curl the Pod IP directly   -> isolates the Service from the app
6. logs + debug               -> the app's own dependencies
EOF

cat ~/lab3/triage/TRIAGE.md
```

---

# Step 14 — Clean up and confirm

## 14.1 — Restore the application

```bash
~/lab3/broken/restore.sh
sleep 30
kps
```

## 14.2 — Compare against the baseline

```bash
{
  echo "===== AFTER 3.4 $(date) ====="
  echo "--- pods ---";           kubectl get pods -o wide
  echo "--- deployments ---";    kubectl get deploy
  echo "--- services ---";       kubectl get svc
  echo "--- endpointslices ---"; kubectl get endpointslices
  echo "--- pvc ---";            kubectl get pvc
} > ~/lab3/triage/after.txt

diff <(grep -E '^(postgres|python-api|node-api|react-frontend)' ~/lab3/triage/baseline.txt | awk '{print $1, $3}') \
     <(grep -E '^(postgres|python-api|node-api|react-frontend)' ~/lab3/triage/after.txt   | awk '{print $1, $3}') \
  && echo "Structure matches the baseline (Pod names will differ; that is expected)."
```

Pod names change, because Pods were recreated. Deployments, Services, endpoints, and the PVC should all match.

## 14.3 — Full end-to-end check

```bash
for p in / /api/py/health /api/py/api/db /api/node/health /api/node/api/db; do
  printf '%-24s ' "$p"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -m 5 "http://localhost:30080$p"
done

kubectl get pvc
curl -sS http://localhost:30080/api/py/api/db; echo
```

**Expect:** five 200s. The PVC still `Bound`. The heartbeat count continuing from before, not restarting at zero, after everything you did to that database container.

From Windows: reload `http://172.31.17.54:30080/`. Both status cards green.

## 14.4 — Remove leftover debugging Pods

```bash
kubectl get pods
kubectl get pods | grep -E 'node-debugger|tmp|curl-test|broken-storage' || echo "none left"
# delete any that remain, by name
```

Ephemeral debug containers added with `kubectl debug` disappear when their Pod is replaced, which `restore.sh` has already done.

## 14.5 — What to keep

**Keep:** `~/lab3/broken/` including both scripts, `~/lab3/triage/TRIAGE.md`, `baseline.txt`, and the netshoot image in the cluster.

Sub-lab 3.5 reuses `08-bad-readiness.yaml` and `02b-liveness.yaml`. `random-break.sh` is worth running again in a few weeks.

```bash
free -h
docker system df
```

---

# Verification checklist

### Method
- [ ] The five-step loop can be recited from memory, in order.
- [ ] The five-layer table can be reproduced, and you can name the component responsible for each layer.
- [ ] `describe` output read on a **healthy** Pod first, so normal output is familiar.
- [ ] Conditions checked before Events as a habit.
- [ ] Exit codes 0, 1, 127, 137, and 143 recognised, and you know that anything above 128 means a signal.
- [ ] Restart backoff understood, including that `rollout restart` resets it.

### Tools
- [ ] `kubectl debug` used to get DNS and HTTP tools inside a Pod that has neither.
- [ ] `kubectl debug node/...` used once. **[PLAT]**
- [ ] `kubectl logs --previous` used to read a container that no longer exists.
- [ ] `kubectl logs -c <init-container>` used, and you know why it is required.
- [ ] A `custom-columns` alias saved.
- [ ] A disposable netshoot Pod used to test a Service from a client's point of view.

### The nine failures, each diagnosed from symptoms
- [ ] 1 `ImagePullBackOff`, including the `imagePullPolicy: Always` variant with a correct tag.
- [ ] 2 `CrashLoopBackOff` from an application error, found only via `--previous`.
- [ ] 2b `CrashLoopBackOff` from an aggressive liveness probe, with **clean logs**.
- [ ] 3 `OOMKilled` — exit 137, empty `--previous` logs, and the cascade into the two APIs.
- [ ] 4 `Pending` from requests, on a node that `kubectl top` shows is nearly idle. **[PLAT]**
- [ ] 5 `CreateContainerConfigError` — `describe` was the only tool that worked.
- [ ] 6 Bad selector — **empty** endpoints, no events anywhere, Pod proven healthy by direct IP.
- [ ] 7 Bad `targetPort` — **populated** endpoints, connection refused on the wrong port.
- [ ] **6 versus 7 stated clearly in your own words.**
- [ ] 8 Readiness failure — `0/1 Running`, 0 restarts, rollout stalled, users unaffected.
- [ ] 9 PVC `Pending` — `describe pod` pointed at a different object. **[PLAT]**
- [ ] **9 compared against Sub-lab 3.2's correct `Pending`**, and the difference is the event message.

### Capstone
- [ ] Compound A localised to the ConfigMap, with the init container preventing a crash loop.
- [ ] Compound B: two failures in two different layers found and separated.
- [ ] The six-step localisation sequence written down.
- [ ] `random-break.sh` and `restore.sh` created and tested.

### Deliverable
- [ ] `TRIAGE.md` written **in your own words**.
- [ ] Application fully restored, five 200s, both status cards green, PVC still `Bound`, heartbeat count continuous.

---

# What this sub-lab bought you

Before this, a broken Pod meant reading documentation and searching for error messages. Now the process is:

**Read the state. The state names the layer. The layer names the command. The command names the cause.**

Nine failures, three of which are indistinguishable from one another in `kubectl get pods` and require different investigations. That set covers the majority of what goes wrong with workloads on Kubernetes. The remainder is mostly the same shapes with different details.

The specific items that come up most often in real work:

1. `--previous`, or you are reading a container that has not failed yet.
2. `get endpointslices`, and read the port as well as the addresses.
3. Clean logs with a crash loop means look at the probes.
4. Read the event message, because the status alone cannot tell normal from broken.

**Next: Sub-lab 3.5.** Replicas, rolling updates, and graceful shutdown. You will break things under load and measure failed requests during a deployment, which is much easier now that you have a procedure instead of a set of guesses.
