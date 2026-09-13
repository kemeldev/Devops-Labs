# Lab 3.5 — Replicas, Rolling Updates, and Graceful Shutdown

Detailed walkthrough. Builds on the `lab3` KinD cluster and the five-service application completed in Sub-labs 3.1 to 3.4.

## Objective

Three related things:

1. Run more than one copy of a service and see the Service distribute traffic across them with no extra configuration. This is the direct answer to the problem Lab 02 Step 8 deferred.
2. Replace a running version with a new one without taking the service down, and control how that replacement happens.
3. Shut a Pod down without losing requests. This is the part most people get wrong, and it is the main reason this sub-lab exists.

Point 3 deserves a warning. If you build a deployment pipeline in Lab 4 without understanding this, you will produce a pipeline that drops a small number of requests on every single deployment, and you will not know it is happening, because the rollout reports success and the Pods look healthy. The only way to find out is to measure it, which is what Step 3 does.

## What You Will Build

No new services. You will:

- Scale `node-api` to three replicas.
- Trigger several rolling updates and control their behavior.
- Measure failed requests during a rollout, then eliminate them.
- Add a small amount of code to the Node application, and build version `0.2.0`.

## Prerequisites

Sub-lab 3.4 completed, the application fully restored, and `TRIAGE.md` written. You will use the triage loop several times here, particularly in Step 4.

## Role Tags

| Tag | Meaning |
|---|---|
| **[DEV]** | Application developer. Replica counts, probes, application shutdown code, Pod specification. |
| **[PLAT]** | Platform or DevOps engineer. Rollout strategy, capacity trade-offs, Service behaviour. |

Step 3, the graceful shutdown work, is mostly [DEV], and this is worth noticing. The fix lives partly in the Pod specification and partly in your application source code. It is not something a platform team can configure on your behalf. That division is the reason so many services ship without it.

## How to Use This Guide

Same format as the previous sub-labs:

- **Run** — the exact commands.
- **Expect** — what a correct result looks like.
- **Why it matters** — the idea to take away.

Sections marked **[Deep dive]** are optional for the checklist.

You will need two SSH sessions for several steps, one to watch and one to act. Open both now.

**Convention:** `$` means a command on the Ubuntu host over SSH. `PS>` means a command on your Windows workstation.

---

## Step 0 — Preparation

### 0.1 — Confirm the Starting State

```bash
kubectl config current-context                    # kind-lab3
kubectl config view --minify | grep namespace:    # multi-service-app
kubectl get pods -o wide
kubectl get svc
kubectl get httproute

for p in / /api/py/health /api/py/api/db /api/node/health /api/node/api/db; do
  printf '%-24s ' "$p"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -m 5 "http://localhost:30080$p"
done
```

**Expect:** four Pods, all 1/1 Running with RESTARTS 0, and five HTTP 200 responses.

### 0.2 — Check Resources

You are about to run three copies of `node-api` plus several load-generating processes.

```bash
free -h
nproc
kubectl get nodes
```

**Expect:** at least 1.5 GB free. Three `node-api` replicas at 64Mi requested each is not much, but the load generator will use real CPU on the host.

### 0.3 — Find Out How a Pod Identifies Itself

Step 1 depends on being able to tell one replica from another in an HTTP response. Check what your application already reports.

```bash
curl -sS http://localhost:30080/api/node/api/info | python3 -m json.tool
curl -sS http://localhost:30080/api/py/api/info   | python3 -m json.tool
```

**Expect:** a field named something like `host`, `hostname`, or `pod`. Note the exact name, because you will use it in Step 1.

**Why this works even without application changes.** Kubernetes sets each container's hostname to the Pod name. So `os.hostname()` in Node, or `socket.gethostname()` in Python, returns something like `node-api-7d9c8b5f4-x2k9p` with no code changes at all. If your application already reports a hostname, you already have per-replica identification.

If you also added the Downward API reporting from the master plan's application-changes table, you will additionally see the node name, which makes Step 1 clearer. Check whether the environment variables are at least present:

```bash
POD=$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- env | grep -E '^(POD_|NODE_)'
```

**Expect:** `POD_NAME`, `NODE_NAME`, and `POD_IP`. These were added in Sub-lab 3.3 §1.3. Whether the application reports them is a separate matter, and Step 1 works either way.

### 0.4 — Build the Load Generator

This is the measuring instrument for the whole sub-lab. Without it, Step 3 is a discussion rather than an experiment.

```bash
mkdir -p ~/lab3/loadtest
cd ~/lab3/loadtest

cat > load.sh <<'SH'
#!/usr/bin/env bash
# Sends requests in parallel for a fixed number of seconds.
# Records one HTTP status code per line, per worker, then combines them.
#
# usage: ./load.sh <seconds> <concurrency> <url> <label>
set -u
SECS="${1:-60}"
CONC="${2:-4}"
URL="${3:?need a url}"
LABEL="${4:-run}"

DIR="$HOME/lab3/loadtest/results"
mkdir -p "$DIR"
rm -f "$DIR/${LABEL}"*.raw

END=$(( $(date +%s) + SECS ))
echo "Sending requests to $URL"
echo "Duration ${SECS}s, concurrency ${CONC}, label '${LABEL}'"

for i in $(seq 1 "$CONC"); do
  (
    while [ "$(date +%s)" -lt "$END" ]; do
      curl -s -o /dev/null -m 3 -w '%{http_code}\n' "$URL" 2>/dev/null || echo "000"
    done
  ) > "$DIR/${LABEL}.${i}.raw" &
done
wait

cat "$DIR/${LABEL}."*.raw > "$DIR/${LABEL}.txt"
rm -f "$DIR/${LABEL}."*.raw
echo "Finished. Results in $DIR/${LABEL}.txt"
SH

cat > report.sh <<'SH'
#!/usr/bin/env bash
# usage: ./report.sh <label>
set -u
LABEL="${1:?need a label}"
F="$HOME/lab3/loadtest/results/${LABEL}.txt"
[ -f "$F" ] || { echo "No results file: $F"; exit 1; }

TOTAL=$(wc -l < "$F")
OK=$(grep -c '^200$' "$F" || true)
BAD=$(( TOTAL - OK ))
if [ "$TOTAL" -gt 0 ]; then
  PCT=$(python3 -c "print(f'{$BAD/$TOTAL*100:.2f}')")
else
  PCT="0.00"
fi

echo "=============================="
echo " label    : $LABEL"
echo " total    : $TOTAL"
echo " HTTP 200 : $OK"
echo " failed   : $BAD  (${PCT}%)"
echo "=============================="
echo "breakdown by status code:"
sort "$F" | uniq -c | sort -rn | sed 's/^/  /'
SH

chmod +x load.sh report.sh
ls -l
```

A note on status code `000`. That is not an HTTP code. `curl` writes `000` when it never received a response at all, which means the connection was refused, reset, or timed out. In this sub-lab, `000` and `502` are the two failures you will see, and they mean slightly different things:

- **`000`** — the connection to the proxy itself failed, or curl timed out.
- **`502`** — Traefik answered, but could not get a response from the backend Pod.

### 0.5 — Establish a Baseline of Zero Failures

Before measuring a rollout, confirm the instrument reads zero when nothing is happening.

```bash
cd ~/lab3/loadtest
./load.sh 30 4 "http://localhost:30080/api/node/api/info" baseline
./report.sh baseline
```

**Expect:** `failed: 0 (0.00%)` and several thousand requests.

**Why it matters:** if the baseline shows failures, something is already wrong and every later measurement is meaningless. Also note the request count, which tells you the rate your host can produce. You will need enough requests in flight during a rollout to catch a window that lasts a second or two.

If the baseline shows a small number of `000` results, your host is saturated. Reduce concurrency to 2 and try again.

---

## Step 1 — Replicas and Service Load Balancing [DEV]

### 1.1 — Scale Up, the Quick Way

```bash
kubectl get deploy node-api
kubectl scale deployment node-api --replicas=3
kubectl rollout status deployment/node-api --timeout=120s
kubectl get pods -l app=node-api -o wide
```

**Expect:** three Pods, all 1/1 Running, distributed across `lab3-worker` and `lab3-worker2`. Two on one node and one on the other is normal. None on the control-plane node, because of the taint from Sub-lab 3.1 §2.6.

**Why the distribution is uneven.** The scheduler spreads Pods of the same Deployment across nodes as a soft preference, not a hard rule. With three Pods and two eligible nodes it cannot be even. Sub-lab 3.6 covers how to make spreading a requirement using `topologySpreadConstraints`.

### 1.2 — Confirm the Service Picked Them Up With No Changes

```bash
kubectl get endpointslices -l kubernetes.io/service-name=node-api
kubectl get endpointslices -l kubernetes.io/service-name=node-api \
  -o jsonpath='{.items[*].endpoints[*].addresses}'; echo
```

**Expect:** three IP addresses where there was one.

**Why it matters.** You did not edit the Service. You did not restart Traefik. You did not reload any configuration. You changed a number on a Deployment, and traffic distribution across three backends started working.

This is the label-selector indirection from Sub-lab 3.1 §4.3 paying off. The Service holds a query, `app=node-api`. A controller continuously watches for Pods matching that query and writes their addresses into an EndpointSlice. Three matching Pods means three addresses. The Service has no idea that anything changed, because from its point of view nothing did.

Compare this with Lab 02. Scaling a Compose service to three copies required a load balancer in front, an upstream block naming the backends, and a configuration reload. Here it required one integer.

### 1.3 — Watch Requests Distribute Across Replicas

First through the Service, from inside the cluster. This removes Traefik from the picture so you are measuring only Kubernetes.

```bash
FIELD=host

kubectl run tmp \
  --rm -i \
  -n multi-service-app \
  --image=nicolaka/netshoot:latest \
  --restart=Never \
  -- sh -c '
    for i in $(seq 1 60); do
      curl -sS -m 3 http://node-api/api/info | jq -c . || echo "{\"host\":\"FAILED\"}"
    done
  ' | FIELD="$FIELD" python3 -c '
import os, sys, json, collections

field = os.environ.get("FIELD", "host")
c = collections.Counter()

for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue

    try:
        d = json.loads(line)
    except Exception:
        continue

    c[d.get(field) or d.get("host") or d.get("hostname") or d.get("pod") or "?"] += 1

for k, v in c.most_common():
    print(f"{v:>4}  {k}")
'
```

Expect roughly twenty requests to each of the three Pod names. Something like:

```
  24  node-api-7d9c8b5f4-x2k9p
  19  node-api-7d9c8b5f4-m4n8q
  17  node-api-7d9c8b5f4-p7v2r
```

Now through the Gateway, which is what a real user experiences:

```bash
for i in $(seq 1 60); do
  curl -sS -m 3 http://localhost:30080/api/node/api/info | jq -c .
done | python3 -c "
import sys, json, collections
c = collections.Counter()

for line in sys.stdin:
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    c[d.get('host') or d.get('hostname') or d.get('pod') or '?'] += 1

for k, v in c.most_common():
    print(f'{v:>4}  {k}')
"
```

**Expect:** a similar spread.

> **An important correction to a common expectation**
>
> You may have read that a Kubernetes Service does "round robin" load balancing, meaning it cycles through backends in strict order: Pod 1, Pod 2, Pod 3, Pod 1, and so on.
>
> That is not what happens. In its default iptables mode, kube-proxy selects a backend at random with equal probability for each new connection. Over many requests the distribution is roughly even, but there is no rotation, and consecutive requests can easily hit the same Pod several times.
>
> Check which mode your cluster uses:
> ```bash
> kubectl get configmap kube-proxy -n kube-system -o yaml | grep -A2 'mode:'
> docker exec lab3-worker iptables-save -t nat 2>/dev/null | grep -c 'statistic mode random' || true
> ```
> The `statistic mode random` rules are the mechanism. In IPVS mode, kube-proxy can do true round robin and several other algorithms, but IPVS is not the default.
>
> **Why this matters in practice.** If you send three requests and all three reach the same Pod, nothing is broken. If you are writing a test that asserts strict rotation, the test is wrong. And if your service holds per-request state in memory, random distribution will surface that bug faster than rotation would.

### 1.4 — Do It Declaratively, and Look at the Drift You Created

```bash
kubectl diff -f ~/lab3/msa/10-node-api-deployment.yaml
```

**Expect:** a difference showing `replicas: 3` in the cluster and `replicas: 1` in the file.

This is the same lesson as Sub-lab 3.1 §5.6, now with a real service. `kubectl scale` produced state that exists nowhere in your files. If you or anyone else runs `kubectl apply -f` on that file, the replica count silently drops back to 1.

Fix the file so the cluster and the file agree:

```bash
sed -i 's/^  replicas: 1$/  replicas: 3/' ~/lab3/msa/10-node-api-deployment.yaml
grep -n '^  replicas:' ~/lab3/msa/10-node-api-deployment.yaml

kubectl diff -f ~/lab3/msa/10-node-api-deployment.yaml && echo "No difference. File and cluster agree."
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
```

**Why it matters.** `kubectl scale`, `kubectl edit`, and `kubectl patch` are convenient and they all create the same problem: the running system no longer matches the description of the system. In a small lab you can remember what you did. In a team, someone else runs `apply` and undoes your change without ever seeing it. Sub-lab 3.10 makes `kubectl diff -k` a routine step before every apply, and this is the reason.

Keeping `replicas` in the file also raises a real question that Sub-lab 3.6 will answer: once a HorizontalPodAutoscaler is managing the replica count, the file and the cluster will disagree permanently and by design. The usual solution is to remove `replicas` from the manifest entirely so the autoscaler owns it.

### 1.5 — Three Writers Instead of One

```bash
curl -sS http://localhost:30080/api/node/api/db | python3 -m json.tool
sleep 30
curl -sS http://localhost:30080/api/node/api/db | python3 -m json.tool
```

**Expect:** the heartbeat count for the Node table increasing roughly three times faster than before, because three Pods are now writing to it independently.

**The question worth sitting with.** Is this application stateless?

Mostly. Each replica handles requests without needing to know about the others, which is what allows random distribution to work. But each replica is also writing rows to a shared table on a timer. Scaling to three replicas did not just triple the capacity, it tripled the write rate to the database. Nothing broke, but the behaviour of the system changed in a way that has nothing to do with serving requests.

This is the usual shape of the problem. Services are rarely completely stateless. They are stateless for request handling and stateful somewhere else: a background timer, a cache, a scheduled job, a file on local disk. Scaling reveals it. Lab 02 Step 8 raised this and could not demonstrate it; now you can see it in a row count.

### 1.6 — Session Affinity, and Why It Is a Poor Tool

```bash
kubectl patch svc node-api -p '{"spec":{"sessionAffinity":"ClientIP"}}'
kubectl get svc node-api -o jsonpath='{.spec.sessionAffinity}{"\n"}'

kubectl run tmp \
  --rm -i \
  -n multi-service-app \
  --image=nicolaka/netshoot:latest \
  --restart=Never \
  -- sh -c '
    for i in $(seq 1 20); do
      curl -sS -m 3 http://node-api/api/info | jq -c . || echo "{\"host\":\"FAILED\"}"
    done
  ' | python3 -c '
import sys, json, collections

c = collections.Counter()

for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue

    try:
        d = json.loads(line)
    except Exception:
        continue

    c[d.get("host") or d.get("hostname") or d.get("pod") or "?"] += 1

for k, v in c.most_common():
    print(f"{v:>4}  {k}")
'
```

**Expect:** all twenty requests reach the same Pod. Distribution has stopped.

Now test through the Gateway:

```bash
for i in $(seq 1 20); do
  curl -sS -m 3 http://localhost:30080/api/node/api/info | jq -c . || echo '{"host":"FAILED"}'
done | python3 -c '
import sys, json, collections

c = collections.Counter()

for line in sys.stdin:
    line = line.strip()
    if not line.startswith("{"):
        continue

    try:
        d = json.loads(line)
    except Exception:
        continue

    c[d.get("host") or d.get("hostname") or d.get("pod") or "?"] += 1

for k, v in c.most_common():
    print(f"{v:>4}  {k}")
'
```

**Expect:** also all to one Pod, and probably a different Pod than before.

**Why it matters, and why this is usually the wrong tool.**

`sessionAffinity: ClientIP` works at the network layer. kube-proxy hashes the source IP address and sends every connection from that address to the same backend, for three hours by default.

The problem is what "client IP" means by the time a packet reaches kube-proxy:

- Your browser's requests arrive at Traefik. Traefik opens its own connections to the backend. As far as kube-proxy is concerned, the client is Traefik, not your browser. So every user in the world shares one affinity entry, and all traffic goes to one Pod.
- Behind corporate network address translation, thousands of users share one public IP and therefore one Pod.
- A mobile user changing network loses their session.

That is why the Gateway test above sent everything to a single Pod. Affinity is working exactly as specified, and the specification is not useful here.

The correct tool for keeping a user on one backend is a cookie set by the proxy, which operates at the HTTP layer and identifies the actual user. Traefik can do this, and Gateway API is adding standardised support for it. The better answer is usually to remove the need for affinity by storing session state in a shared place such as the database or a cache.

Turn it off:

```bash
kubectl patch svc node-api -p '{"spec":{"sessionAffinity":"None"}}'
kubectl get svc node-api -o jsonpath='{.spec.sessionAffinity}{"\n"}'
```

### 1.7 — [Deep Dive] externalTrafficPolicy on the Traefik Service

Your Traefik Service is a NodePort, and it has a setting that will matter on EKS.

```bash
kubectl get svc -n traefik -o jsonpath='{.items[0].spec.externalTrafficPolicy}{"\n"}'
kubectl get pods -n traefik -o wide
```

**Expect:** `Cluster`, and the Traefik Pod on one specific worker node.

**What `Cluster` means.** Every node accepts traffic on port 30080, including nodes with no Traefik Pod. A node that has no local Pod forwards the packet to a node that does. That extra hop requires source network address translation, which replaces the original client IP address. This is why access logs behind a NodePort often show node IPs rather than real client addresses.

**What `Local` would mean.** Only nodes actually running a Traefik Pod would accept the traffic. No extra hop, so the client IP is preserved. But nodes without a Pod would refuse the connection entirely.

Do not set `Local` on this cluster. Your host port mapping is on `lab3-control-plane`, and Traefik runs on a worker. With `Local`, the control-plane node would stop accepting traffic on 30080 and your application would become unreachable from Windows.

This is worth understanding now because on EKS it is a real decision with real consequences, and the usual solution is to run the ingress controller as a DaemonSet so that every node has a local Pod.

---

## Step 2 — Rolling Updates [PLAT]

### 2.1 — Look at the Machinery Before Using It

```bash
kubectl get deploy node-api
kubectl get rs -l app=node-api
kubectl get deploy node-api -o jsonpath='{.spec.strategy}' | python3 -m json.tool
```

Expect the default strategy:

```json
{
  "rollingUpdate": {
    "maxSurge": "25%",
    "maxUnavailable": "25%"
  },
  "type": "RollingUpdate"
}
```

Work out what those percentages mean at three replicas, because the rounding is not obvious:

- **`maxSurge`:** 25% of 3 is 0.75, and `maxSurge` rounds up, giving 1. At most one extra Pod above the desired count may exist during a rollout, so up to 4 total.
- **`maxUnavailable`:** 25% of 3 is 0.75, and `maxUnavailable` rounds down, giving 0. Zero Pods may be unavailable, so at least 3 must be ready at all times.

```bash
kubectl describe deploy node-api | grep -iE 'replicas|strategy|rollingupdate'
```

**Why the rounding goes in opposite directions.** Kubernetes rounds in whichever direction is safer. Rounding surge up means you are allowed more capacity. Rounding unavailable down means you are allowed less downtime. With the defaults at three replicas, the result is a rollout that never reduces capacity, which is a sensible default.

Remember the ownership chain from Sub-lab 3.1 §5.4: a Deployment owns ReplicaSets, and a ReplicaSet owns Pods. A rolling update is the Deployment creating a second ReplicaSet and gradually moving replicas from the old one to the new one. The Deployment never touches Pods directly.

### 2.2 — Trigger a Rollout and Watch It

In session A:

```bash
kubectl get pods -l app=node-api -w
```

In session B:

```bash
kubectl rollout restart deployment/node-api
```

**Expect in session A:** a new Pod appears and reaches 1/1, then an old Pod terminates. Repeated three times. The count of ready Pods never drops below three, and briefly reaches four.

Stop the watch and look at what happened:

```bash
kubectl rollout status deployment/node-api
kubectl get rs -l app=node-api
kubectl rollout history deployment/node-api
```

**Expect:** two ReplicaSets. The old one at DESIRED 0, the new one at DESIRED 3. The history shows at least two revisions.

What `rollout restart` actually did:

```bash
kubectl get deploy node-api -o jsonpath='{.spec.template.metadata.annotations}' | python3 -m json.tool
```

**Expect:** an annotation `kubectl.kubernetes.io/restartedAt` with a timestamp.

**Why it matters.** A Deployment only starts a rollout when its Pod template changes. Changing the replica count does not trigger one. Editing a ConfigMap does not trigger one, which is the surprise you observed in Sub-lab 3.2 §13. `rollout restart` works by writing a timestamp into the Pod template, which changes the template, which triggers a rollout. It is a small trick, and knowing it explains why some changes cause a restart and others do not.

This is also the mechanism behind the fix that Sub-lab 3.10 introduces. Kustomize's `configMapGenerator` adds a content hash to the ConfigMap's name, so changing a value changes the name, which changes the Pod template, which triggers a rollout automatically. The same idea, applied automatically.

### 2.3 — Roll Back

```bash
kubectl rollout history deployment/node-api
kubectl rollout undo deployment/node-api
kubectl rollout status deployment/node-api
kubectl get rs -l app=node-api
```

**Expect:** the two ReplicaSets swap. The previously-empty one goes to 3, and the other to 0.

**Why rollback is nearly instantaneous.** Nothing is rebuilt or downloaded. The old ReplicaSet has been sitting at zero replicas with its complete Pod template intact. Rolling back means scaling it back up and scaling the new one down. That is the reason those empty ReplicaSets are kept rather than deleted.

```bash
kubectl get deploy node-api -o jsonpath='{.spec.revisionHistoryLimit}{"\n"}'
```

**Expect:** `10`, the default. That is how many old ReplicaSets are retained, and therefore how far back you can roll. Lower it to 2 or 3 in real clusters, because each retained ReplicaSet is an object in etcd.

### 2.4 — Change the Strategy and Feel the Trade-Off [PLAT]

This is the part that turns two YAML fields into a decision you understand.

**Configuration 1:** `maxUnavailable: 0`, `maxSurge: 1` (the default behaviour)

Already tested above. Capacity never drops. Requires room for one extra Pod.

**Configuration 2:** `maxSurge: 0`, `maxUnavailable: 1`

```bash
kubectl patch deploy node-api -p \
  '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":1}}}}'
```

Session A:

```bash
watch -n1 'kubectl get pods -l app=node-api; echo; kubectl get endpointslices -l kubernetes.io/service-name=node-api'
```

Session B:

```bash
kubectl rollout restart deployment/node-api
```

**Expect:** the total Pod count never exceeds three, and drops to two while a replacement starts. Your endpoint count drops to two as well. You are running at two thirds capacity for part of the rollout.

**Configuration 3:** `maxSurge: 0`, `maxUnavailable: 0`

```bash
kubectl patch deploy node-api -p \
  '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":0,"maxUnavailable":0}}}}'
kubectl rollout restart deployment/node-api
sleep 10
kubectl get pods -l app=node-api
kubectl rollout status deployment/node-api --timeout=30s
```

**Expect:** nothing happens. The rollout cannot start.

**Why:** you have told Kubernetes it may not add a Pod and may not remove a Pod. There is no legal first move. The rollout waits forever.

**Why it matters.** These two fields are where you choose which cost to pay during a deployment:

| Setting | Cost | Use when |
|---|---|---|
| `maxUnavailable: 0`, `maxSurge > 0` | needs spare cluster capacity for extra Pods | capacity is available, and you cannot reduce throughput |
| `maxSurge: 0`, `maxUnavailable > 0` | reduced capacity during the rollout | the cluster is full, or each Pod is expensive |
| both 0 | the rollout never proceeds | never |

There is no configuration that gives you full capacity and no extra Pods. Deploying a new version requires temporarily having either more Pods than usual or fewer working ones. Choosing between those is a platform decision, and it depends on how much spare capacity you are paying for.

Restore the default:

```bash
kubectl patch deploy node-api -p \
  '{"spec":{"strategy":{"rollingUpdate":{"maxSurge":"25%","maxUnavailable":"25%"}}}}'
kubectl rollout status deployment/node-api --timeout=120s
kubectl get pods -l app=node-api
```

### 2.5 — minReadySeconds

```bash
kubectl patch deploy node-api -p '{"spec":{"minReadySeconds":15}}'

time kubectl rollout restart deployment/node-api
time kubectl rollout status deployment/node-api --timeout=180s
```

**Expect:** the rollout takes considerably longer, roughly 15 extra seconds per Pod.

**What it does.** Normally a Pod counts as available the moment its readiness probe first passes. `minReadySeconds: 15` means it must stay ready continuously for 15 seconds before the Deployment moves on to the next replica.

**Why it matters.** A Pod that passes readiness once and then crashes two seconds later is not healthy, but without `minReadySeconds` the rollout has already moved on and may replace all your working Pods with broken ones. `minReadySeconds` makes the rollout slower and much harder to break. It is one of the cheapest safety settings available.

```bash
kubectl patch deploy node-api -p '{"spec":{"minReadySeconds":0}}'
```

### 2.6 — progressDeadlineSeconds and a Stalled Rollout

```bash
kubectl get deploy node-api -o jsonpath='{.spec.progressDeadlineSeconds}{"\n"}'
```

**Expect:** `600`, the default, which is ten minutes. Shorten it so you are not waiting.

```bash
kubectl patch deploy node-api -p '{"spec":{"progressDeadlineSeconds":60}}'

# Deploy an image tag that does not exist
kubectl set image deployment/node-api node-api=node-api:9.9.9
kubectl rollout status deployment/node-api --timeout=90s
```

**Expect:** after about sixty seconds, `error: deployment "node-api" exceeded its progress deadline`.

```bash
kubectl get pods -l app=node-api
kubectl describe deploy node-api | sed -n '/Conditions:/,/OldReplicaSets/p'
```

Expect:

```
Conditions:
  Type             Status  Reason
  Available        True    MinimumReplicasAvailable
  Progressing      False   ProgressDeadlineExceeded
```

Read those two lines together. `Available: True` means your users are fine. `Progressing: False` means the deployment gave up.

Two important points.

**Your application never went down.** The three old Pods are still running and serving traffic. The new Pod is stuck in `ImagePullBackOff`, which you diagnosed in Sub-lab 3.4 Step 3. `maxUnavailable: 0` prevented Kubernetes from removing a working Pod before a replacement was ready, and no replacement ever became ready. The safety setting did its job.

**Kubernetes does not roll back automatically.** The Deployment reports the failure and stops. It will sit in this state indefinitely. There is no built-in automatic rollback.

**Why this matters for Lab 4.** Automatic rollback is your pipeline's responsibility. A correct deployment job looks roughly like:

```bash
kubectl set image ... && kubectl rollout status --timeout=5m || kubectl rollout undo ...
```

The `rollout status` command returns a non-zero exit code when the deadline is exceeded, which is exactly what a pipeline needs in order to detect the failure and react. Write that down for Lab 4.

Fix it:

```bash
kubectl rollout undo deployment/node-api
kubectl rollout status deployment/node-api --timeout=120s
kubectl get pods -l app=node-api
kubectl patch deploy node-api -p '{"spec":{"progressDeadlineSeconds":600}}'
```

### 2.7 — [Deep Dive] Pause and Resume: a Manual Canary

```bash
kubectl rollout pause deployment/node-api
kubectl set image deployment/node-api node-api=node-api:0.1.0
kubectl get pods -l app=node-api
```

**Expect:** nothing happens. The Pod template changed but the rollout is paused.

```bash
kubectl rollout resume deployment/node-api
kubectl rollout status deployment/node-api --timeout=120s
```

The useful pattern is to pause in the middle:

```bash
kubectl rollout restart deployment/node-api
sleep 6
kubectl rollout pause deployment/node-api
kubectl get pods -l app=node-api -o wide
kubectl get rs -l app=node-api
```

**Expect:** a mix of Pods from both ReplicaSets, frozen. Some requests go to the new version and some to the old.

You can now inspect logs, check error rates, and decide. Then either:

```bash
kubectl rollout resume deployment/node-api     # proceed
# or
kubectl rollout undo deployment/node-api       # go back
```

```bash
kubectl rollout resume deployment/node-api
kubectl rollout status deployment/node-api --timeout=120s
```

**Why it matters.** This is a canary deployment built from primitives you already have. Note the limitation: the traffic split is determined by the Pod count, so with three replicas your smallest possible canary is one third of traffic. Compare this with the Gateway API weighted split from Sub-lab 3.3 §7, where 10% of traffic went to one backend with two integers and no relationship to replica counts. That is the difference between controlling traffic by replica count and controlling it by routing rule, and it is why Gateway API weights are the better tool.

---

## Step 3 — Graceful Shutdown [DEV]

This is the centre of the sub-lab. Everything above was preparation.

### 3.1 — Measure the Problem With the Current Configuration

In session A, start the load generator:

```bash
cd ~/lab3/loadtest
./load.sh 60 4 "http://localhost:30080/api/node/api/db" before
```

Wait about five seconds, then in session B:

```bash
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=120s
```

When session A finishes:

```bash
cd ~/lab3/loadtest
./report.sh before
```

**Expect:** a small number of failures. Something like:

```
 total    : 3184
 HTTP 200 : 3161
 failed   : 23  (0.72%)
breakdown by status code:
   3161 200
     19 502
      4 000
```

The exact number will vary, and it may be small. If you see zero failures, go straight to §3.2, which makes the mechanism unmistakable.

Note which endpoint you used. `/api/db` performs a database round trip, so each request takes longer than `/health`. A longer request means a wider window in which a Pod can be killed mid-request. Slow endpoints lose more requests, which is the opposite of what people expect.

Record the number. This is your "before" figure.

### 3.2 — Make the Mechanism Unmistakable

Failures may have been few, for a reason worth understanding: Traefik watches EndpointSlices directly. It does not rely on kube-proxy. When a Pod starts terminating, Traefik learns about it and removes the backend from its own pool, often faster than kube-proxy reprograms its rules. A modern ingress controller therefore reduces this problem considerably.

It does not eliminate it. Traefik still holds open connections to the terminating Pod, and requests already in flight still fail when the process dies.

To see the mechanism clearly, remove the grace period so the process is killed almost immediately:

```bash
kubectl patch deploy node-api -p '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":1}}}}'
kubectl rollout status deployment/node-api --timeout=120s
```

Session A:

```bash
cd ~/lab3/loadtest
./load.sh 60 4 "http://localhost:30080/api/node/api/db" harsh
```

Session B, after five seconds:

```bash
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=120s
```

```bash
./report.sh harsh
```

**Expect:** noticeably more failures than the before run.

**What you just changed.** `terminationGracePeriodSeconds` is the time the kubelet waits between sending SIGTERM and sending SIGKILL. The default is 30 seconds. You set it to 1, so every request the Pod was handling was destroyed one second later.

Also test the Service directly, with Traefik removed from the path:

```bash
kubectl run loadgen --image=nicolaka/netshoot:latest --restart=Never -- sh -c '
  END=$(( $(date +%s) + 60 ))
  while [ "$(date +%s)" -lt "$END" ]; do
    curl -s -o /dev/null -m 3 -w "%{http_code}\n" http://node-api/api/db 2>/dev/null || echo 000
  done'
sleep 5
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=120s
sleep 20
kubectl logs loadgen | sort | uniq -c | sort -rn
kubectl delete pod loadgen
```

**Expect:** failures here too, mostly `000`, meaning the connection was refused or reset rather than answered with an error. This is the raw kube-proxy path with no proxy smoothing it over.

### 3.3 — the Mechanism, Precisely

This is the explanation. Read it slowly, because almost every incorrect fix for this problem comes from misunderstanding the order of events.

When a Pod is deleted, whether by `kubectl delete pod`, a rollout, a scale-down, or a node drain, two sequences begin at the same time and do not coordinate with each other:

```
t=0   API server records deletionTimestamp on the Pod

PATH A: removing it from traffic          PATH B: stopping the process
================================          ============================
t=0   EndpointSlice controller marks the        kubelet begins termination
      address as terminating / removes it
t≈0.1 kube-proxy on node 1 reprograms rules     kubelet runs the preStop hook,
t≈0.3 kube-proxy on node 2 reprograms rules     if one is defined, and waits
t≈0.3 kube-proxy on node 3 reprograms rules     for it to finish
t≈0.5 Traefik updates its backend pool
                                          t=?   kubelet sends SIGTERM to PID 1

                                          the application does whatever
                                          it does on SIGTERM

                                          t=grace   kubelet sends SIGKILL if the
                                                     process is still alive
```

The problem is the gap between the two columns. Path A takes time to reach every node and every proxy. If Path B sends SIGTERM before Path A has finished, there is a window in which traffic is still being sent to a Pod that has begun shutting down.

Nothing here is misconfigured. This is documented, expected behaviour. Kubernetes does not wait for endpoint removal to propagate before sending SIGTERM, because it has no way to know when propagation is complete. Every proxy, every node, and every service mesh learns about the change independently.

There are therefore two distinct problems, and they need two distinct fixes:

| Problem | Description | Fix |
|---|---|---|
| The race | New requests arrive after SIGTERM, because a proxy has not learned yet | `preStop` hook that delays SIGTERM |
| In-flight requests | Requests already accepted are destroyed when the process stops | SIGTERM handler in the application |

Doing only one of the two does not solve it. This is the point people miss. Worse, adding only a SIGTERM handler can change the failure without reducing it, which §3.5 demonstrates.

### 3.4 — Fix 1: the preStop Hook

```bash
kubectl patch deploy node-api -p '{
  "spec": {"template": {"spec": {
    "terminationGracePeriodSeconds": 30,
    "containers": [{
      "name": "node-api",
      "lifecycle": {"preStop": {"exec": {"command": ["sleep", "10"]}}}
    }]
  }}}}'
kubectl rollout status deployment/node-api --timeout=180s
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].lifecycle}' | python3 -m json.tool
```

Measure again:

```bash
cd ~/lab3/loadtest
./load.sh 90 4 "http://localhost:30080/api/node/api/db" prestop
```

Session B, after five seconds:

```bash
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=180s
```

```bash
./report.sh prestop
./report.sh before
```

**Expect:** substantially fewer failures than before, and far fewer than harsh. Possibly zero, possibly a handful.

**What the sleep does.** The kubelet runs the preStop command and waits for it to finish before sending SIGTERM. During those ten seconds the container is completely untouched and serving normally. Meanwhile Path A finishes: every kube-proxy and Traefik remove the address. By the time SIGTERM arrives, nothing is sending new requests.

Note what the sleep does not do. It does not make the application handle shutdown correctly. It does not protect requests already in progress when SIGTERM finally arrives. It only wins the race.

> **This looks wrong and it is the standard answer**
>
> Deliberately doing nothing for ten seconds in order to let a distributed system catch up feels like a workaround, because it is one. It is also the accepted solution, recommended in the Kubernetes documentation and used in essentially every production deployment that cares about this.
>
> The reason there is nothing better is that Kubernetes cannot know when every proxy in the cluster has learned about the change. There is no acknowledgement and no completion signal. A fixed delay longer than propagation usually takes is the only mechanism available.
>
> **A practical note on the value.** Five to fifteen seconds is typical. Whatever you choose, `terminationGracePeriodSeconds` must be larger than the preStop duration plus the time your longest request takes, or the sleep gets killed partway through. §3.8 demonstrates exactly that mistake.
>
> And one warning. `sleep` must exist inside your container image. In a minimal or distroless image it may not, and the hook fails silently. Check with `kubectl exec <pod> -- sleep 1`. If it is missing, use `httpGet` against an endpoint in your application instead.

### 3.5 — Fix 2: Handle SIGTERM in the Application

Now the half that the Pod specification cannot provide. This requires editing the Node application.

**First, see what happens today**

```bash
POD=$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- sh -c 'kill -TERM 1' 2>/dev/null || true
sleep 3
kubectl get pods -l app=node-api
kubectl describe pod "$POD" | grep -A4 'Last State' || true
```

**Expect:** the container stopped almost immediately. Node's default behaviour on SIGTERM is to exit the process, with no opportunity for in-flight requests to complete.

**Add the shutdown handler**

Find where your Express application starts listening:

```bash
cd ~/multi-service-App/api-node
ls
grep -rn "app.listen" . --include=*.js | grep -v node_modules
```

You will have something similar to:

```javascript
app.listen(PORT, () => {
  console.log(`Node API listening on ${PORT}`);
});
```

Replace it with the following. Adjust variable names to match your file.

```javascript
// ---------------------------------------------------------------
// Graceful shutdown
// ---------------------------------------------------------------
let shuttingDown = false;

const server = app.listen(PORT, () => {
  console.log(`Node API listening on ${PORT}`);
});

// Make sure idle keep-alive connections do not outlive us.
// Without this, server.close() can wait a long time for connections
// that are open but not carrying a request.
server.keepAliveTimeout = 5000;
server.headersTimeout = 6000;

function shutdown(signal) {
  if (shuttingDown) return;
  shuttingDown = true;
  console.log(`[shutdown] ${signal} received, draining connections`);

  // Stop accepting new connections. The callback runs once every
  // existing connection has finished.
  server.close(() => {
    console.log('[shutdown] all connections closed, exiting cleanly');
    process.exit(0);
  });

  // Close connections that are open but idle, so server.close()
  // is not waiting on them. Available in Node 18.2 and later.
  if (typeof server.closeIdleConnections === 'function') {
    server.closeIdleConnections();
  }

  // Safety net: if draining takes too long, exit anyway.
  // This must be shorter than terminationGracePeriodSeconds.
  setTimeout(() => {
    console.log('[shutdown] drain timed out, forcing exit');
    process.exit(0);
  }, 15000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT',  () => shutdown('SIGINT'));
```

Optional but good practice. Make the health endpoint report that shutdown has begun:

```javascript
app.get('/health', (req, res) => {
  if (shuttingDown) {
    return res.status(503).json({ status: 'shutting down' });
  }
  res.json({ status: 'ok' });
});
```

> **A precision that many articles get wrong.** During Pod deletion, flipping readiness to failing is not what removes the Pod from the Service. The EndpointSlice controller removes terminating Pods regardless of their readiness state, as soon as the deletion timestamp is set. So the readiness flag is not the fix for the race; the preStop hook is.
>
> The flag is still worth having, because it is correct behaviour and it matters in other situations, such as when a load balancer performs its own health checks independently of Kubernetes endpoints. Add it, but do not rely on it for this problem.

**Build and deploy version 0.2.0**

```bash
cd ~/multi-service-App/api-node
docker build -t node-api:0.2.0 .
docker images node-api

kind load docker-image node-api:0.2.0 --name lab3
for n in lab3-control-plane lab3-worker lab3-worker2; do
  docker exec "$n" crictl images | grep 'node-api.*0.2.0' >/dev/null \
    && echo "$n OK" || echo "$n MISSING"
done
```

Update the manifest properly rather than using `kubectl set image`, so the file and the cluster stay in agreement:

```bash
sed -i 's|image: node-api:0.1.0|image: node-api:0.2.0|' ~/lab3/msa/10-node-api-deployment.yaml
grep -n 'image: node-api' ~/lab3/msa/10-node-api-deployment.yaml

kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=180s
```

Wait: the preStop hook you added in §3.4 was applied with `kubectl patch`, so it is not in the file, and this apply just removed it.

```bash
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].lifecycle}'; echo
```

**Expect:** empty.

This is the imperative-versus-declarative lesson again, and this time it removed a fix rather than a replica count. It is exactly the situation §1.4 warned about. Put both settings in the file where they belong:

```bash
python3 - <<'EOF'
import os
p = os.path.expanduser('~/lab3/msa/10-node-api-deployment.yaml')
s = open(p).read()

if 'terminationGracePeriodSeconds' not in s:
    s = s.replace(
        "      automountServiceAccountToken: false\n",
        "      automountServiceAccountToken: false\n"
        "      # Must exceed preStop duration + longest request duration\n"
        "      terminationGracePeriodSeconds: 30\n"
    )

if 'preStop' not in s:
    s = s.replace(
        "          securityContext:\n            runAsNonRoot: true\n"
        "            allowPrivilegeEscalation: false\n"
        "            capabilities:\n              drop: [\"ALL\"]\n"
        "            seccompProfile:\n              type: RuntimeDefault\n",
        "          lifecycle:\n"
        "            preStop:\n"
        "              exec:\n"
        "                # Keep serving while endpoint removal propagates\n"
        "                command: [\"sleep\", \"10\"]\n"
        "          securityContext:\n            runAsNonRoot: true\n"
        "            allowPrivilegeEscalation: false\n"
        "            capabilities:\n              drop: [\"ALL\"]\n"
        "            seccompProfile:\n              type: RuntimeDefault\n"
    )

open(p, 'w').write(s)
EOF

grep -n -B2 -A6 'lifecycle\|terminationGracePeriod' ~/lab3/msa/10-node-api-deployment.yaml
```

If that substitution did not match your file exactly, edit it by hand. The container specification needs:

```yaml
      terminationGracePeriodSeconds: 30      # at the pod spec level
      containers:
        - name: node-api
          image: node-api:0.2.0
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "10"]
```

Apply and verify:

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=180s

kubectl get deploy node-api -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].lifecycle}' | python3 -m json.tool
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl diff -f ~/lab3/msa/10-node-api-deployment.yaml && echo "File and cluster agree."
```

**Confirm the handler runs**

```bash
POD=$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].metadata.name}')
kubectl delete pod "$POD" --wait=false
sleep 4
kubectl logs "$POD" --tail=20 2>/dev/null || echo "(pod already gone; try again and read faster)"
```

Expect to see your shutdown messages:

```
[shutdown] SIGTERM received, draining connections
[shutdown] all connections closed, exiting cleanly
```

Reading these logs is a race against deletion. A more reliable approach is to watch the logs continuously in session A and delete the Pod in session B:

```bash
# Session A
kubectl logs -f -l app=node-api --prefix --tail=1

# Session B
kubectl delete pod "$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].metadata.name}')"
```

### 3.6 — Measure the Complete Fix

```bash
cd ~/lab3/loadtest
./load.sh 90 4 "http://localhost:30080/api/node/api/db" fixed
```

Session B, after five seconds:

```bash
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=180s
```

```bash
echo; echo "###### BEFORE (no preStop, no handler) ######"; ./report.sh before
echo; echo "###### HARSH (grace period of 1 second) ######"; ./report.sh harsh
echo; echo "###### PRESTOP ONLY ######";                     ./report.sh prestop
echo; echo "###### FULLY FIXED ######";                      ./report.sh fixed
```

**Expect:** zero failures in the fixed run.

Make it harder to be sure it holds:

```bash
./load.sh 120 6 "http://localhost:30080/api/node/api/db" fixed-hard
```

Session B:

```bash
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=180s
sleep 5
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=180s
```

```bash
./report.sh fixed-hard
```

**Expect:** still zero, across two consecutive rollouts and higher concurrency.

**What you have accomplished.** You produced, measured, and eliminated the most common cause of "we see a few errors every time we deploy" in the industry. Most teams never measure it, so they never know it is happening. The rollout reports success. The Pods are healthy. The error rate is under one percent, which looks like normal background noise on a dashboard.

Write down the two halves of the fix, because they are separate and both are required:

1. **preStop hook**, in the Pod specification, so the container keeps serving while the cluster learns it is going away.
2. **A SIGTERM handler**, in the application source code, so requests already accepted are allowed to finish.

And the constraint that links them: `terminationGracePeriodSeconds` must be larger than the preStop duration plus the longest request duration.

### 3.7 — Break It: the Grace Period Mistake

This is the error people make when they add the preStop hook and forget the arithmetic.

```bash
kubectl patch deploy node-api -p '{"spec":{"template":{"spec":{"terminationGracePeriodSeconds":5}}}}'
kubectl rollout status deployment/node-api --timeout=180s
```

Your preStop sleeps for 10 seconds. Your grace period is now 5 seconds.

```bash
cd ~/lab3/loadtest
./load.sh 90 4 "http://localhost:30080/api/node/api/db" broken-grace
```

Session B:

```bash
kubectl rollout restart deployment/node-api
kubectl rollout status deployment/node-api --timeout=180s
```

```bash
./report.sh broken-grace
```

**Expect:** the failures are back.

**Why.** `terminationGracePeriodSeconds` is a deadline on the whole termination sequence, not just on the time after SIGTERM. The clock starts when deletion begins. Your preStop sleep needs 10 seconds and only has 5, so at 5 seconds the kubelet sends SIGKILL. The sleep is killed, the SIGTERM handler never runs at all, and the process is destroyed with requests in flight.

```bash
kubectl describe pod -l app=node-api | grep -iE 'Exit Code|Reason' | head -6
```

**Expect:** exit code 137, which is 128 + 9, meaning SIGKILL. You recognise this from Sub-lab 3.4 Step 5, where it meant out of memory. Here it means the grace period expired. Same exit code, different cause, which is a good reminder that exit code 137 means "killed" and not specifically "out of memory."

**Why this is a worthwhile mistake to have seen.** Nothing warns you. The API server accepts the configuration. The rollout reports success. Both settings look reasonable on their own. The failure only appears under load, and it is invisible in any single Pod's description. The arithmetic is your responsibility:

```
terminationGracePeriodSeconds  >  preStop duration + longest request duration
                          30   >  10 + (a few seconds)     ✓
                           5   >  10 + (a few seconds)     ✗
```

Restore the correct value:

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=180s
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.terminationGracePeriodSeconds}{"\n"}'
```

### 3.8 — Compare the Two Frameworks [DEV]

Your Python service was never modified. Test it the same way.

```bash
cd ~/lab3/loadtest
./load.sh 60 4 "http://localhost:30080/api/py/api/db" python-before
```

Session B:

```bash
kubectl rollout restart deployment/python-api
kubectl rollout status deployment/python-api --timeout=180s
```

```bash
./report.sh python-before
```

**Expect:** fewer failures than `node-api` produced, and possibly zero.

```bash
kubectl logs -l app=python-api --tail=30 | tail -15
```

**Why the difference.** uvicorn, which runs FastAPI, installs its own SIGTERM handler. On SIGTERM it stops accepting new connections, waits for in-flight requests to complete, and then exits. You get half of the fix for free, purely because of the framework you chose.

Express does not do this. `app.listen()` returns a server and leaves shutdown entirely to you. Node's default response to SIGTERM is to exit immediately.

The lesson worth taking from this. "Does my application shut down gracefully?" is a question about your framework, your web server, and your own code. It is not a Kubernetes question, and it has a different answer in every language. Two services in the same cluster, with identical manifests, can behave completely differently.

Python still needs the preStop hook, because the race in Path A is independent of anything the application does. Add it:

```bash
python3 - <<'EOF'
import os
p = os.path.expanduser('~/lab3/msa/07-python-api-deployment.yaml')
s = open(p).read()
if 'terminationGracePeriodSeconds' not in s:
    s = s.replace("    spec:\n      # Runs to completion",
                  "    spec:\n      terminationGracePeriodSeconds: 30\n      # Runs to completion", 1)
print("Edit this file by hand if the automatic change did not apply:")
print(p)
open(p,'w').write(s)
EOF

grep -n 'terminationGracePeriodSeconds' ~/lab3/msa/07-python-api-deployment.yaml
```

Add the lifecycle block to the `python-api` container by hand, matching what you did for `node-api`:

```yaml
          lifecycle:
            preStop:
              exec:
                command: ["sleep", "10"]
```

```bash
kubectl apply -f ~/lab3/msa/07-python-api-deployment.yaml
kubectl rollout status deployment/python-api --timeout=180s
kubectl get deploy python-api -o jsonpath='{.spec.template.spec.containers[0].lifecycle}' | python3 -m json.tool
```

Verify:

```bash
./load.sh 60 4 "http://localhost:30080/api/py/api/db" python-fixed
```

Session B:

```bash
kubectl rollout restart deployment/python-api
kubectl rollout status deployment/python-api --timeout=180s
```

```bash
./report.sh python-fixed
```

**Expect:** zero failures.

### 3.9 — [Deep Dive] Apply the Same Fix to the Frontend

`react-frontend` is nginx serving static files. Requests complete in milliseconds, so in-flight losses are unlikely, but the race in Path A applies to it exactly the same way.

```bash
python3 - <<'EOF'
import os
p = os.path.expanduser('~/lab3/msa/12-react-frontend-deployment.yaml')
s = open(p).read()
if 'terminationGracePeriodSeconds' not in s:
    s = s.replace("      automountServiceAccountToken: false\n",
                  "      automountServiceAccountToken: false\n"
                  "      terminationGracePeriodSeconds: 30\n")
open(p,'w').write(s)
EOF

grep -n 'terminationGracePeriod' ~/lab3/msa/12-react-frontend-deployment.yaml
```

Add a preStop hook to the nginx container as well. A useful detail: nginx has its own graceful shutdown command, `nginx -s quit`, which finishes current requests before exiting. So a better hook is:

```yaml
          lifecycle:
            preStop:
              exec:
                command: ["sh", "-c", "sleep 10 && nginx -s quit"]
```

That waits for endpoint removal to propagate and then shuts nginx down gracefully. Note that nginx's default response to SIGTERM is a fast shutdown that drops connections, while `nginx -s quit` is the graceful one, so the hook is doing real work here rather than just sleeping.

```bash
kubectl apply -f ~/lab3/msa/12-react-frontend-deployment.yaml
kubectl rollout status deployment/react-frontend --timeout=120s
```

Postgres is a deliberate exception. It uses `strategy: Recreate` and has one replica, as decided in Sub-lab 3.2 §6.3, so there is no overlap and no graceful rollout to achieve. Graceful shutdown for a database is about finishing transactions and writing a clean shutdown checkpoint, not about connection draining. Sub-lab 3.9 addresses Postgres properly when it becomes a StatefulSet.

---

## Step 4 — Break It: a Stalled Rollout Under Load [DEV] + [PLAT]

Combine everything. Use the triage loop from Sub-lab 3.4.

### 4.1 — Break It

```bash
ls -l ~/lab3/broken/08-bad-readiness.yaml
```

That file points the readiness probe at `/healthz`, which does not exist. It was written for `node-api:0.1.0`, so bring it up to date first:

```bash
sed -i 's|image: node-api:0.1.0|image: node-api:0.2.0|' ~/lab3/broken/08-bad-readiness.yaml
sed -i 's/^  replicas: 1$/  replicas: 3/' ~/lab3/broken/08-bad-readiness.yaml
grep -nE 'image:|replicas:|path: /health' ~/lab3/broken/08-bad-readiness.yaml
```

Session A:

```bash
cd ~/lab3/loadtest
./load.sh 120 4 "http://localhost:30080/api/node/api/db" stalled
```

Session B, after five seconds:

```bash
kubectl apply -f ~/lab3/broken/08-bad-readiness.yaml
kubectl rollout status deployment/node-api --timeout=60s
```

> **Diagnose before reading on**
>
> Use the triage loop. Answer these:
> 1. What did `rollout status` report, and what does that tell you?
> 2. What state are the Pods in? How many of each?
> 3. Which layer, from the Sub-lab 3.4 table, has failed?
> 4. What do the endpoints show?
> 5. How many requests failed?

### 4.2 — the Diagnosis

```bash
kubectl get pods -l app=node-api -o wide
kps
```

**Expect:** three Pods at 1/1 Running from the old ReplicaSet, plus one new Pod at 0/1 Running with RESTARTS 0.

```bash
kubectl get rs -l app=node-api
```

**Expect:** the old ReplicaSet still at 3, the new one at 1 and stuck there.

```bash
BAD=$(kubectl get pods -l app=node-api -o json | python3 -c "
import sys, json
for p in json.load(sys.stdin)['items']:
    cs = p['status'].get('containerStatuses', [{}])[0]
    if not cs.get('ready'): print(p['metadata']['name']); break")
kubectl describe pod "$BAD" | sed -n '/^Conditions:/,/^Volumes:/p'
kubectl describe pod "$BAD" | sed -n '/^Events:/,$p'
```

**Expect:** `ContainersReady: False`, and a warning that the readiness probe failed with status code 404. This is failure 8 from Sub-lab 3.4, exactly as you diagnosed it there. Layer 5.

```bash
kubectl get endpointslices -l kubernetes.io/service-name=node-api -o yaml | grep -cE 'ready: true'
```

**Expect:** three ready endpoints, the three old Pods. The unready new Pod is excluded.

### 4.3 — Now Read the Measurement

```bash
cd ~/lab3/loadtest
./report.sh stalled
```

**Expect:** zero failures, or very close to it.

This is the point of the exercise. You deployed a broken version. The rollout failed. And not one user was affected.

Three things worked together:

1. `maxUnavailable: 0` meant Kubernetes could not remove a working Pod until a replacement was ready.
2. The readiness probe correctly reported that the new Pod was not ready.
3. The endpoint controller kept the unready Pod out of the Service.

The rollout stopped, on purpose, with the old version still serving. Nothing rolled back, nothing was lost, and nothing needed a human until someone looked.

**Learn to read a stalled rollout as good news.** The instinctive reaction to `rollout status` timing out is that something has gone badly wrong. What it actually means is that Kubernetes caught a bad deployment and refused to complete it. The bad outcome would have been a rollout that succeeded and replaced three working Pods with three broken ones. That happens when readiness probes are missing, or when they check something that is always true, such as a TCP port being open.

Write this down for Lab 4. A pipeline that runs `kubectl rollout status --timeout=5m` and rolls back on a non-zero exit code turns this stall into an automatic recovery. The pieces are all here; Lab 4 connects them.

### 4.4 — Fix

```bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=180s
kps
kubectl get rs -l app=node-api
```

**Expect:** three ready Pods, the broken ReplicaSet scaled to zero.

---

## Step 5 — Clean Up and Confirm

### 5.1 — Make Sure the Files Match the Cluster

This is the most important cleanup step, because you used `kubectl patch` many times in this sub-lab.

```bash
for f in ~/lab3/msa/05-postgres-deployment.yaml \
         ~/lab3/msa/07-python-api-deployment.yaml \
         ~/lab3/msa/10-node-api-deployment.yaml \
         ~/lab3/msa/11-node-api-service.yaml \
         ~/lab3/msa/12-react-frontend-deployment.yaml; do
  echo "===== $(basename "$f") ====="
  kubectl diff -f "$f" || true
done
```

**Expect:** no differences. Any difference is a change you made with `patch` that never made it into a file. Decide whether you want it, and either put it in the file or remove it from the cluster.

Confirm the settings that matter are in the files, not just in the cluster:

```bash
echo "--- replicas ---"
grep -n '^  replicas:' ~/lab3/msa/10-node-api-deployment.yaml
echo "--- image ---"
grep -n 'image: node-api' ~/lab3/msa/10-node-api-deployment.yaml
echo "--- grace periods ---"
grep -n 'terminationGracePeriodSeconds' ~/lab3/msa/*.yaml
echo "--- preStop hooks ---"
grep -n -A3 'preStop' ~/lab3/msa/*.yaml
echo "--- session affinity should NOT appear ---"
grep -n 'sessionAffinity' ~/lab3/msa/*.yaml || echo "  (none, correct)"
```

### 5.2 — Full End-to-End Check

```bash
kps
kubectl get deploy,rs,svc
kubectl get endpointslices

for p in / /api/py/health /api/py/api/db /api/node/health /api/node/api/db; do
  printf '%-24s ' "$p"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -m 5 "http://localhost:30080$p"
done

kubectl get pvc
curl -sS http://localhost:30080/api/py/api/db | python3 -m json.tool
```

**Expect:** five HTTP 200. The PVC still `Bound`. Heartbeat counts continuing rather than restarting at zero, after everything you did in this sub-lab.

From Windows: reload `http://172.31.17.54:30080/`. Both status cards green.

### 5.3 — Record Your Results

```bash
cd ~/lab3/loadtest
{
  echo "# Sub-lab 3.5 graceful shutdown results — $(date)"
  echo
  for label in before harsh prestop fixed fixed-hard broken-grace python-before python-fixed stalled; do
    [ -f "results/${label}.txt" ] || continue
    echo "## $label"
    ./report.sh "$label"
    echo
  done
} > ~/lab3/loadtest/RESULTS.md

cat ~/lab3/loadtest/RESULTS.md
```

Keep this. A recorded before-and-after measurement is far more convincing than a description, both to yourself in six months and to anyone you explain this to.

### 5.4 — Decide About Replicas

Three `node-api` replicas cost about 200 MB. Sub-lab 3.6 needs at least three for the anti-affinity and PodDisruptionBudget work, so keep them if you have the memory. If you are short:

```bash
sed -i 's/^  replicas: 3$/  replicas: 1$/' ~/lab3/msa/10-node-api-deployment.yaml
# then fix the stray '$' the sed above introduces, or just edit by hand
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
```

Scaling back up for 3.6 is one line, so there is no cost to reducing it now.

### 5.5 — What to Keep

Keep: `~/lab3/loadtest/` including both scripts and `RESULTS.md`, the updated manifests in `~/lab3/msa/`, `~/lab3/broken/`, the `node-api:0.2.0` image, and your `TRIAGE.md`.

The load generator is reusable. Sub-lab 3.6 uses it to drive a HorizontalPodAutoscaler, and Sub-lab 3.10 can use it to confirm that a Kustomize-driven rollout is also clean.

```bash
free -h
docker system df
docker images node-api
```

You can remove the old image tag if disk is tight, but keep `0.1.0` if you would like to practise rollbacks:

```bash
# optional
# docker rmi node-api:0.1.0
```

---

## Verification Checklist

**Replicas and Load Balancing [DEV]**

- [ ] `node-api` scaled to 3, Pods spread across both worker nodes.
- [ ] EndpointSlice went from one address to three with no Service change.
- [ ] Requests observed reaching all three Pods, through the Service and through the Gateway.
- [ ] Understood that kube-proxy distributes randomly, not in strict rotation, and found the `statistic mode random` rules.
- [ ] `kubectl diff` used to find the drift that `kubectl scale` created, and the file corrected.
- [ ] Heartbeat write rate tripled, and the "is this stateless?" question answered honestly.
- [ ] `sessionAffinity: ClientIP` stopped distribution, and you can explain why it sends everything to one Pod when behind a proxy.
- [ ] (Deep dive) `externalTrafficPolicy` understood, including why `Local` would break this cluster.

**Rolling Updates [PLAT]**

- [ ] Default `maxSurge`/`maxUnavailable` at 3 replicas computed correctly (1 and 0), including the rounding directions.
- [ ] A rollout watched from start to finish; two ReplicaSets identified.
- [ ] Understood that `rollout restart` works by changing an annotation in the Pod template.
- [ ] `rollout undo` performed, and you can explain why it is nearly instant.
- [ ] All three strategy configurations tested, including `maxSurge: 0` with `maxUnavailable: 0` which never proceeds.
- [ ] The trade-off stated in your own words: either extra Pods or reduced capacity, never neither.
- [ ] `minReadySeconds` slowed a rollout, and you can explain what it protects against.
- [ ] `progressDeadlineSeconds` exceeded; `Available: True` with `Progressing: False` read correctly.
- [ ] Confirmed that Kubernetes does not roll back automatically, and noted the implication for Lab 4.
- [ ] (Deep dive) Rollout paused mid-way, both ReplicaSets serving, then resumed.

**Graceful Shutdown [DEV]**

- [ ] Baseline of zero failures established before measuring anything.
- [ ] Failures measured during a rollout with the original configuration.
- [ ] Failure count amplified with `terminationGracePeriodSeconds: 1` so the mechanism was unmistakable.
- [ ] The two-path timeline explained: endpoint removal and process termination run in parallel and do not coordinate.
- [ ] Understood the two separate problems: the propagation race, and in-flight requests.
- [ ] preStop hook added; failures measurably reduced.
- [ ] SIGTERM handler added to the Express application; `node-api:0.2.0` built and deployed.
- [ ] Shutdown log messages observed during a Pod deletion.
- [ ] Zero failures measured across two consecutive rollouts at higher concurrency.
- [ ] Broke it with a grace period shorter than the preStop duration; failures returned; exit code 137 observed.
- [ ] The arithmetic written down: grace period > preStop + longest request.
- [ ] `python-api` compared and found to behave better by default, because uvicorn handles SIGTERM.
- [ ] Understood that this is a framework and application question, not a Kubernetes question.
- [ ] preStop also added to `python-api` and `react-frontend`; Postgres correctly excluded.

**Stalled Rollout**

- [ ] Broken readiness probe deployed under load.
- [ ] Diagnosed with the triage loop; identified as layer 5.
- [ ] Zero failed requests measured, and you can name the three mechanisms that protected users.
- [ ] Can explain why a stalled rollout is a better outcome than a successful one here.

**Discipline**

- [ ] `kubectl diff` clean against every manifest at the end.
- [ ] Every fix lives in a file, not only in the cluster.
- [ ] `RESULTS.md` saved with before-and-after numbers.
- [ ] Five HTTP 200, both status cards green, PVC still `Bound`, heartbeat counts continuous.

---

## Troubleshooting

**The load generator reports failures even at steady state**

Your host is saturated by the generator itself. Reduce concurrency to 2, or use `/api/info` instead of `/api/db` so each request is cheaper. Re-establish a clean baseline before trusting any measurement.

**Zero failures in the before run**

Good, and expected sometimes. Traefik watches EndpointSlices directly and removes terminating backends quickly. Use §3.2 to make the mechanism visible: set `terminationGracePeriodSeconds: 1`, use `/api/db`, raise concurrency, and also test the Service directly with the in-cluster loadgen Pod.

**The preStop hook appears to do nothing**

```bash
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].lifecycle}'; echo
POD=$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].metadata.name}')
kubectl exec "$POD" -- sh -c 'command -v sleep' || echo "sleep is NOT in this image"
```

If `sleep` is missing, the hook fails silently. Use `httpGet` against an application endpoint instead, or `["sh","-c","sleep 10"]` if a shell is present.

**`kubectl apply` removed a setting I added with `kubectl patch`**

That is correct behaviour, and it is the §1.4 lesson. `apply` makes the cluster match the file. Anything not in the file is removed. Put the setting in the file.

**Shutdown log messages never appear**

```bash
kubectl get deploy node-api -o jsonpath='{.spec.template.spec.containers[0].image}'; echo
```

If it still says `0.1.0`, the new image was not deployed. If it says `0.2.0`, check that your handler is registered on `process.on('SIGTERM', ...)` and that nothing else in the file calls `process.exit()` first. Also confirm your application is PID 1: if the container starts through a shell wrapper, the shell may receive SIGTERM and never pass it on.

```bash
kubectl exec "$POD" -- ps -o pid,comm 2>/dev/null || kubectl exec "$POD" -- ps aux
```

**Expect** your Node process as PID 1. If PID 1 is `sh` or `npm`, that is the problem. Use the exec form of `CMD` in your Dockerfile, for example `CMD ["node", "server.js"]` rather than `CMD node server.js`.

**The rollout will not start at all**

```bash
kubectl get deploy node-api -o jsonpath='{.spec.strategy}' | python3 -m json.tool
kubectl rollout resume deployment/node-api 2>/dev/null || true
```

Either both strategy values are 0, from §2.4, or the Deployment is still paused from §2.7.

**502 failures continue after the full fix**

Check the arithmetic from §3.7, and check the drain timeout inside your handler. The `setTimeout` safety net must be shorter than `terminationGracePeriodSeconds`, otherwise SIGKILL arrives before your forced exit.

---

## [PARKED] — for a Future Pass

- **Progressive delivery with Argo Rollouts or Flagger.** These automate what you did by hand in §2.7: shift a small percentage of traffic, watch metrics, and roll forward or back automatically. They need a metrics source, so this belongs after an observability lab.
- **Cookie-based session affinity** through Traefik or Gateway API, which is the correct answer to the problem `sessionAffinity: ClientIP` solves badly.
- **Blue-green deployment** by switching a Service selector between two full sets of Pods. Instant cutover and instant rollback, at the cost of running two complete copies.
- **`topologySpreadConstraints`** to make the Pod distribution in §1.1 a requirement rather than a preference. Sub-lab 3.6.
- **`PodDisruptionBudget`**, which protects these replicas during a node drain rather than during a rollout. Sub-lab 3.6.
- **Traffic mirroring**, sending a copy of live traffic to a new version with no user impact.
- **Connection draining at the load balancer**, which is the same race one layer further out. On EKS, target group deregistration delay is the equivalent setting, and forgetting it reproduces this entire problem outside the cluster.

---

## What This Sub-Lab Bought You

The scaling half answered the question Lab 02 Step 8 deferred. Running three copies of a service and distributing traffic across them took one integer, no load balancer configuration, and no reload. That is what an orchestrator provides over Compose.

The rollout half turned `maxSurge` and `maxUnavailable` from documentation into a decision you can explain, and showed you that a failed rollout with `Available: True` is a system working correctly rather than an incident.

The graceful shutdown half is the part worth remembering. You measured a real defect that most teams never notice, understood exactly why it happens, fixed both halves of it, and measured zero. The four points to retain:

1. Endpoint removal and process termination happen in parallel and do not coordinate.
2. A preStop hook wins the race. A SIGTERM handler saves in-flight requests. You need both.
3. `terminationGracePeriodSeconds` must exceed the preStop duration plus your longest request.
4. Whether your application shuts down cleanly depends on your framework, and the answer differs between languages even with identical manifests.

**Next:** Sub-lab 3.6. Resource requests, quality of service classes, scheduling, and node lifecycle. It starts by installing metrics-server and finding out how wrong the resource requests you guessed actually are, then covers drain and PodDisruptionBudget, which is the same class of problem as this sub-lab, one layer out: how to take a whole node away without losing requests.
