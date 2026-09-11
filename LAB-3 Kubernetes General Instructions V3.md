Lab 03 (v3) — Running the Multi-Service App on Kubernetes (KinD)
Revision note. Supersedes v1 and v2. Sub-labs 3.1 and 3.2 are complete and stay as built. Eight sub-labs remain (3.3–3.10). v2's 13-sub-lab scope was over-built for this learning path; the cut content is preserved in the Parked sections rather than deleted.
Two hard constraints in this revision:
	1. No cluster rebuild. The lab3 cluster stays exactly as it is. Every sub-lab below works against the existing 1 control-plane + 2 worker cluster with kindnet, using the extraPortMappings already declared in 3.1. Anything requiring a rebuild is parked and, where it matters, given a throwaway-second-cluster workaround.
	2. Scope ends at competence, not expertise. The target is: deploy, debug, and operate a real app on Kubernetes unsupervised, with a procedure rather than a feeling when it breaks. Expertise comes from production incidents, not labs.

Role tags — what you're learning and who does it
Every part of every sub-lab carries one of these. The point is that you can see which hat you're wearing, and which parts you can safely deprioritise.
Tag	Role	What it means
[DEV]	Application developer on Kubernetes	Writes Deployments, Services, ConfigMaps, probes, resource requests. Reads logs. Debugs their own app. Never installs a CNI. This is the floor — everyone who touches Kubernetes needs all of it.
[PLAT]	Platform / DevOps engineer	Builds and operates the cluster other people's apps run on. Ingress controllers, RBAC, scheduling, storage classes, packaging, CI/CD wiring, IaC. This is your target role.
[SRE]	Cluster administrator / control-plane SRE	etcd, certificate rotation, kubeadm upgrades, API server flags, encryption-at-rest. On EKS you buy this rather than build it. Included only where it makes the layer above legible.
[PARKED]	Future work	Real and valuable, deliberately deferred. Either it belongs in a later lab where the cloud gives it a reason to exist, or it costs more than it returns right now.
Rough distribution across 3.3–3.10: ~40% DEV, ~50% PLAT, ~5% SRE, and the rest is the connective tissue between them.
Where the parked work actually goes
Parked topic	Better home	Why there
Prometheus / Grafana / alerting	Its own lab, or the EKS lab	Deserves a lab, not a sub-lab section. Also the heaviest RAM item on your host.
Operators + CloudNativePG	EKS lab	You will be forced to install operators on EKS (AWS Load Balancer Controller, EBS CSI, External Secrets). Learning what one is with a real reason beats an exercise.
Secrets management (ESO, Sealed Secrets, SOPS)	EKS + GitHub Actions labs	Meaningless without a real secret store or a real git-based pipeline. Both arrive in those labs.
Cluster autoscaling (Karpenter / Cluster Autoscaler)	EKS lab	KinD cannot add nodes. The lesson is structurally impossible here.
Authoring a Helm chart	Later, if ever	Consuming charts (3.10) is the skill you need. Authoring is for people distributing software to strangers.
GitOps (Argo CD / Flux)	GitHub Actions lab	It's a CI/CD architecture decision, not a Kubernetes one.
etcd backup/restore, cert expiry, kubeadm upgrades, CRD authoring	Cut for this path	Pure [SRE]. AWS manages all of it on EKS. Revisit only if you decide to sit the CKA.

Environment (unchanged)
Role	Hostname	IP	Software
KinD host	ubuntuserver1.ssa.veeam.local	172.31.17.54	Docker + kubectl + kind, lab3 cluster
Control point	Windows workstation	172.24.209.0/24	SSH + browser
Existing cluster: 1 control-plane + 2 workers, kindnet CNI, extraPortMappings 30080→30080 and 30443→30443 on the control-plane node, multi-service-app namespace set as the context default.

Decisions locked in for v3
	• The extraPortMappings from 3.1 are the entry point. Any ingress controller or gateway gets exposed as a NodePort Service on 30080/30443, not via hostPort. This is why those ports were declared at cluster creation, and it means no rebuild. See the 3.3 warning box.
	• kindnet stays. NetworkPolicy is therefore parked, with a throwaway-second-cluster workaround if you want it later. Note that EKS's VPC CNI also doesn't enforce NetworkPolicy without explicitly enabling it, so this lesson recurs there naturally.
	• Both Ingress and Gateway API in 3.3, because ingress-nginx is retired but you'll still inherit Ingress objects everywhere. Ingress is the literacy pass; Gateway API is the one you'd build on.
	• Kustomize for your own app; Helm for consuming other people's. Both in 3.10. Chart authoring parked.
	• Every sub-lab from 3.4 onward ends with a break-it exercise. Required, not optional.
	• 3.2 retrofits are additive only — no rebuild, no data loss, ~20 minutes total.
	• The declarative-completeness test lands at the end of 3.10, not before, because that's when Kustomize makes it cheap. It deletes and restores the namespace, never the cluster.

App changes this lab requires
Do these in one sitting, early. All small.
Change	Needed by	Notes
maintenance/cleanup.py + minimal Dockerfile — deletes heartbeat rows older than N minutes from both tables	3.7	Keep it dumb: connect, DELETE, log the row count, exit 0.
SIGTERM handler in both APIs — stop accepting connections, drain in-flight, exit	3.5	Express: server.close() on SIGTERM. uvicorn handles it if you don't swallow it — verify. Without this, 3.5's central exercise has no fix to demonstrate.
/admin/ready toggle — flips an in-memory flag that the readiness endpoint reports on	3.4, 3.5	Lets you fail readiness at runtime without editing a manifest. Used in three sub-labs.
/burn?ms=N — busy-loop for N ms	3.6 (optional HPA part)	while (Date.now() - start < ms) {} is fine.
Downward API in /api/info — report spec.nodeName, Pod name, Pod IP	3.5	Makes 3.5's round-robin visible at node level, not just Pod level.

Retrofits to 3.2 — additive, no rebuild (~20 min)
You built 3.2 correctly. These are additions.
	1. [DEV] Add a startupProbe to python-api, then delete livenessProbe.initialDelaySeconds. You already read about this in your 3.2 deep dive; now make it real. Then deliberately remove the startup probe and set liveness to initialDelaySeconds: 2 and watch a perfectly healthy Pod CrashLoopBackOff forever. This is one of the most common real-world Kubernetes failures and it is invisible from logs.
	2. [DEV] Add securityContext to both containers: runAsNonRoot: true, allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}, seccompProfile: {type: RuntimeDefault}. Hold off on readOnlyRootFilesystem — that's a 3.8 exercise. Doing the easy four now means 3.8's Pod Security Admission step mostly passes on the first try.
	3. [DEV] Add the Downward API per the app-changes table.
	4. [DEV] Try immutable: true on a copy of python-api-config, edit it, read the rejection, delete the copy. Two minutes. Immutable ConfigMaps are both a safety feature and a performance one — the kubelet stops watching them entirely.
	5. [DEV] Add resource requests and limits to both containers if they aren't there yet. Guess badly on purpose; 3.6 fixes them with measurement.
Your PGDATA subdirectory fix and envFrom usage are already correct — nothing to do there.

Sub-lab 3.3 — Completing the translation + the entry point
Primary role: [DEV] for the workloads, [PLAT] for the entry point. This sub-lab is the clearest illustration of the dev/platform boundary in all of Kubernetes.
	⚠️ Read this before installing anything
	Your kind-lab3.yaml maps host ports 30080 and 30443 into the control-plane node. It does not map 80/443.
	The standard KinD ingress-nginx manifest configures the controller with hostPort: 80 and hostPort: 443, plus a node selector pinning it to the control-plane. On your cluster that installs cleanly and is completely unreachable from Windows, because nothing maps those host ports.
	Fix, no rebuild required: expose the controller as a NodePort Service with nodePort: 30080 / nodePort: 30443, and drop the hostPort settings. Same for Envoy Gateway's Gateway Service, which defaults to type: LoadBalancer and will sit Pending forever on KinD.
	This is exactly why 3.1 declared those port mappings at creation time and flagged them as immutable. That decision is now paying off. Read the KinD ingress manifest, find the three things it patches, and understand what you're changing and why — this is a genuinely instructive twenty minutes.
Part A — The remaining two services [DEV]
	• Repeat 3.2's pattern for node-api: init container gating on Postgres, envFrom + secretKeyRef, probes, securityContext, resources. It should feel mechanical by now. That's the point — you've internalised the pattern.
	• react-frontend is the interesting one. Static nginx, no backend dependency, so: no init container, trivial readiness probe, no Secret. The manifest is dramatically shorter than the APIs'. Notice that this asymmetry is information about the app's architecture, visible in the YAML. Reading a repo's manifests to understand its dependency graph is a real skill.
	• Remember Lab 02's build-time-vs-runtime Vite gotcha: the frontend was built with VITE_PY_API=/api/py. Say out loud why that makes a single entry point work with zero CORS config — the browser only ever talks to one origin.
	• kind load both images, then verify with crictl images on all three nodes exactly as you did in 3.2 §1.3. This is the last sub-lab where kind load is your workflow; 3.10 replaces it.
Part B — Ingress: the literacy pass [PLAT] to install, [DEV] to route
	• Read the retirement notice first so you know what you're installing. Kubernetes SIG Network retired ingress-nginx; best-effort maintenance ended March 2026, with no further releases, bugfixes, or CVE patches. Existing installs keep working and the artifacts remain available, which is why this lab still runs — but the project's own README now tells new users to pick a Gateway API implementation instead.
	• Install ingress-nginx, adapted to NodePort per the warning box above. [PLAT]
	• Write an Ingress mirroring Lab 02's nginx.pathbased.conf: / → react-frontend, /api/py/ → python-api, /api/node/ → node-api, with the rewrite-target annotation for prefix stripping. [DEV]
	• Verify from Windows: http://172.31.17.54:30080/ — both status cards green through one address, kubectl port-forward finally retired.
	• The lesson to extract. Almost everything interesting about that Ingress lives in metadata.annotations, not in the spec: rewrite target, timeouts, body size, auth. Annotations are arbitrary strings. The API server does not validate them. A different controller silently ignores them. That is precisely why Ingress is being replaced, and it's worth being able to say so in one sentence.
	• Break it: typo the annotation key. Nothing complains; routing silently misbehaves. Then typo pathType. The API server rejects it immediately. The difference between "in the schema" and "in an annotation" is the whole story, in two commands.
Part C — Gateway API: the one you'd build on [PLAT] + [DEV]
	• Install the Gateway API CRDs, then Envoy Gateway. [PLAT]
	• kubectl api-resources | grep gateway — new types appeared in your cluster. This is your first CRD, and it arrived because you installed software, not because you wrote one. Connect it to 3.1 §3.6's api-resources deep dive.
	• Create the objects, and notice the ownership split as you go: 
		○ GatewayClass — provided by Envoy Gateway. [PLAT]
		○ Gateway — the listener: ports, protocols, hostnames. Expose it on NodePort 30443/30080. Owned by the platform team. [PLAT]
		○ HTTPRoute — the routing rules. Owned by app teams. Can live in a different namespace from the Gateway. [DEV]
	• Express the same path-based routing as Part B, then compare directly:
	Concern	Ingress	Gateway API
	Listener config	mixed into every Ingress + controller flags	Gateway — one object, platform-owned
	Routing rules	same object as the listener	HTTPRoute — app-owned, separable
	Path rewriting	vendor annotation, unvalidated	filters: [{type: URLRewrite}] — typed, validated
	Header manipulation	vendor annotation	typed filter
	Canary / traffic split	vendor annotation	backendRefs with weight — first-class
	Cross-namespace routing	not really	ReferenceGrant — explicit, auditable
	Portability	poor	the entire design goal
	• Do the canary. [PLAT] Split node-api traffic 90/10 across two backendRefs with different weights. Five lines. This was never expressible in portable Ingress, and it's a direct preview of 3.5's rollout work.
Checkpoint
Both status cards green from Windows through a single address, twice — once via Ingress, once via Gateway API. You can state the Ingress→Gateway API rationale in one sentence that mentions annotations. You can say which of Gateway and HTTPRoute a platform team owns and why that split exists.
[PARKED] for later
TLS termination + cert-manager (needs a real DNS name — belongs with the EKS lab). ReferenceGrant and genuine cross-namespace routing. GRPCRoute, traffic mirroring, retries and timeouts as typed filters. cloud-provider-kind to make type: LoadBalancer actually work on KinD. Migrating an ingress-nginx annotation set to Gateway API — a real 2026 job task, and Traefik's nginx-annotation compatibility layer is the interesting shortcut.

Sub-lab 3.4 — Failure triage
Primary role: [DEV], with [PLAT] on the scheduling and storage failures.
This is the most important sub-lab in the whole series and the one with no substitute. You now have five real services, which means you finally have something worth breaking. The goal is not memorising fixes — it's a diagnostic reflex, a fixed sequence you run before forming any hypothesis.
The triage loop — memorise the order [DEV]
1. kubectl get pods                 → what STATE? (the state names the failure class)
2. kubectl describe pod <name>      → read Events from the BOTTOM up
3. kubectl logs <name>              → and --previous if it restarted
4. kubectl events --for pod/<name>  → or get events --sort-by=.lastTimestamp
5. kubectl exec / kubectl debug     → only now, once you have a hypothesis to test

Steps 1–4 are free and read-only. Most people jump to step 5 and burn twenty minutes inside a container answering a question describe would have answered instantly.
The nine canonical failures
Method: write the broken manifests first, into a ~/lab3/broken/ directory, then come back a day later and diagnose them cold, from symptoms alone, without opening the file. Time yourself.
#	Induce it by	Symptom	What it actually means	Role
1	Typo the image tag	ImagePullBackOff / ErrImagePull	Registry, tag, or auth. In KinD also: you forgot kind load. Note that imagePullPolicy: Always vs IfNotPresent is the difference between working and not on a kind-loaded image.	[DEV]
2	Container command exit 1	CrashLoopBackOff	App started and died. logs --previous is the only place the answer lives.	[DEV]
3	memory: 8Mi on Postgres	OOMKilled under Last State in describe	Hit the hard limit. Surface symptom is identical to #2; cause is completely different.	[DEV]
4	Request cpu: 8	Pending, forever	Scheduler couldn't place it. describe gives a per-node reason. Nothing is wrong with your image or your app.	[PLAT]
5	Reference a Secret key that doesn't exist	CreateContainerConfigError	Stuck between "scheduled" and "started". Neither logs nor exec exist yet — describe only.	[DEV]
6	Typo the Service selector	Everything Running and Ready; requests fail	Empty EndpointSlice. You drilled this in 3.1 §4.5 — confirm the reflex survived.	[DEV]
7	Wrong targetPort on the Service	Same as #6, but endpoints are populated	Connection refused at the Pod, not a routing gap. The #6 vs #7 distinction deserves a full ten minutes.	[DEV]
8	Readiness probe at a bad path — or just flip /admin/ready	Running, never Ready, silently excluded from the Service	Do it at runtime with the toggle and watch endpoints drain live.	[DEV]
9	Non-existent storageClassName in a PVC	PVC Pending, Pod Pending	Two objects stuck, one cause. Teaches that describe pod sometimes points you at a different object. Compare against 3.2's legitimate WaitForFirstConsumer Pending — same word, opposite meaning.	[PLAT]
Tooling to learn here [DEV]
	• kubectl debug — ephemeral containers. Attach netshoot into a running Pod's namespaces to get nslookup, curl, nc, ss, tcpdump inside a slim image that has none of them. This directly solves the problem you hit in 3.2 §11, where you had to fall back to python3 -c "import socket" because the image had no nslookup. Single most useful command most people have never run. 
		○ kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>
		○ kubectl debug node/lab3-worker -it --image=busybox for node-level access. [PLAT]
	• kubectl logs flags that matter: --previous, --since=5m, --all-containers, --tail=50, -c <init-container>, and kubectl logs -l app=node-api --prefix -f for all replicas at once.
	• kubectl get -o custom-columns for scanning many objects at once — the complement to the jsonpath you already use for single fields.
	• crictl as the fallback when kubectl goes blind. [SRE] You met it in 3.1 §3.6; reconnect it here. If kubectl says the Pod is fine and it plainly isn't, crictl ps -a inside the node is the next stop.
Deliverable
A one-page triage table in your own words: Pod state → first command → likely causes. This is the most reusable artifact of the entire lab. Keep it somewhere you'll find it at 2am.
[PARKED]
Node-level debugging in depth (kubelet logs, journalctl inside the node, containerd troubleshooting) — [SRE], and largely invisible on EKS. Ephemeral container internals and the debug profiles.

Sub-lab 3.5 — Replicas, load-balancing, rollouts, and graceful shutdown
Primary role: [DEV] for the pod-spec and app-code work, [PLAT] for the rollout strategy.
Part A — Scaling and load-balancing [DEV]
	• Scale node-api to 3 replicas imperatively, then declaratively, then kubectl diff to see the drift you created. Reinforces 3.1 §5.6.
	• Poll /api/node/api/info through the Gateway and watch Pod name and node name rotate — the Downward API retrofit makes the node visible, which is what turns this from a party trick into a demonstration of scheduling.
	• kubectl get pods -o wide confirms the spread across both workers.
	• Watch node_heartbeat row counts climb faster with three concurrent writers. Then ask the uncomfortable question Lab 02 Step 8 raised: is this app actually stateless? The heartbeat table says "mostly," and "mostly stateless" is where real bugs live.
	• Session affinity: set sessionAffinity: ClientIP and watch rotation stop. Understand it's L4 affinity by source IP — crude, and it collapses behind a NAT or a proxy where every client looks like one IP. Gateway API does cookie-based affinity properly.
Part B — Rolling updates [PLAT]
	• Trigger a rollout, watch kubectl rollout status, inspect both ReplicaSets. You saw this in 3.1 §5.6 with a toy; now it's a real service behind a real entry point.
	• Tune maxSurge and maxUnavailable. maxUnavailable: 0 requires spare capacity. maxSurge: 0, maxUnavailable: 1 accepts reduced capacity instead. There is no free lunch, and these two fields are where you choose which cost to pay.
	• kubectl rollout pause / resume — the canary primitive that predates Gateway API weights. Pause with 1 of 3 Pods on the new version and leave it there while you check something.
	• minReadySeconds — why "Ready for 0 seconds" is not the same as healthy.
	• progressDeadlineSeconds — deploy an image that will never become Ready and watch the Deployment report ProgressDeadlineExceeded instead of hanging forever. It does not auto-rollback. That's your CI's job, which is a direct hook into the GitHub Actions lab.
Part C — Graceful shutdown [DEV] — the centrepiece
The highest-value exercise in this sub-lab, and the one v1 and v2 of this plan would have let you get wrong without noticing.
	1. Prove the problem. node-api at 3 replicas. From a Pod in-cluster, run a tight loop: while true; do curl -s -o /dev/null -w '%{http_code}\n' http://node-api/api/info; done. Trigger a rollout. Count the non-200s. There will be some.
	2. Understand why. When a Pod is deleted, two things happen concurrently, not in sequence:
		○ The endpoint controller removes it from the EndpointSlice, which must then propagate to kube-proxy on every node.
		○ The kubelet sends SIGTERM to the container.
Propagation takes time. During that window, kube-proxy on some nodes is still sending traffic to a Pod that has already started shutting down. Nothing is misconfigured. This is documented behaviour, and it is the single most common cause of "we get errors during every deploy" in the industry.
	3. Fix it in layers, measuring after each:
		○ preStop: exec: ["sleep", "5"] — do nothing for five seconds so endpoint removal wins the race. Crude, ugly, and the standard answer.
		○ A real SIGTERM handler in the app (the code change from the table above): stop accepting new connections, finish in-flight requests, exit.
		○ terminationGracePeriodSeconds longer than your slowest request. Understand this is a deadline — SIGKILL arrives afterward regardless of what you're doing.
	4. Re-run the loop. Zero non-200s.
	5. Break it: terminationGracePeriodSeconds: 1 with preStop: sleep 5. The sleep gets SIGKILLed and the errors return. The grace period must exceed preStop + drain time, and nothing warns you.
Part D — Break-it exercise
Roll out an image whose readiness probe never passes, while under load. Diagnose using 3.4's loop. Notice the Service protects you — traffic keeps flowing to the old Pods and the rollout stalls. Recognising "stalled rollout" as good news is a real skill.
Checkpoint
You can explain, unprompted, why preStop: sleep is necessary even in an app with a perfect SIGTERM handler.
[PARKED]
Progressive delivery with Argo Rollouts or Flagger — automated canary analysis against metrics, which is the natural sequel once you have Prometheus. Topology-aware routing and trafficDistribution. Blue/green via Service selector switching.

Sub-lab 3.6 — Resources, QoS, scheduling, and node lifecycle
Primary role: split. [DEV] owns requests/limits and QoS. [PLAT] owns everything about nodes. This is the sub-lab that makes resources.requests stop being a formality, and it's free because you already have two workers.
Part A — Measure before you guess [PLAT] to install, [DEV] to act on
	• Install metrics-server (needs --kubelet-insecure-tls on KinD — understand why before you add it: the kubelet's serving cert isn't signed by a CA metrics-server trusts).
	• kubectl top nodes / kubectl top pods. Note this didn't work before, because Kubernetes ships no metrics pipeline. Same design as CNI: interface defined, implementation your problem. That pattern is now the third time you've met it (CNI, StorageClass, metrics).
	• Compare kubectl top pod against the requests you guessed in the retrofit. They will be very wrong. Right-size them. This is the single highest-ROI operational task in real Kubernetes and it is the entire reason Part A comes first.
Part B — Requests are the scheduler's currency [DEV] + [PLAT]
	• kubectl describe node lab3-worker → read Allocated resources. It sums requests, not usage. The scheduler does arithmetic on numbers you typed in a YAML file and has no idea what your app actually does.
	• Over-request deliberately (cpu: 900m × 5 replicas) and watch Pods go Pending on a node that is 95% idle. This is failure #4 from 3.4, now with the mechanism visible. Requests are a reservation, and the gap between reservation and reality is where most cluster cost lives.
Part C — QoS classes [DEV]
	• Create three Pods; check kubectl get pod X -o jsonpath='{.status.qosClass}': 
		○ Guaranteed — requests == limits, every resource, every container.
		○ Burstable — requests set, limits higher or absent.
		○ BestEffort — nothing set.
	• This determines eviction order under node pressure and OOM-kill priority. Reproduce Lab 02 Step 10's OOM experiment, Kubernetes-native, and observe the BestEffort Pod dying first regardless of who caused the pressure.
	• Then decide per service which class you want, and write down why. Postgres should be Guaranteed. The frontend can be Burstable. That's an architecture decision expressed in four YAML lines.
Part D — Placement controls [PLAT]
Do these four. The full ladder is parked.
Control	Exercise
nodeSelector	Label a worker disktype=ssd, pin Postgres to it. Simplest possible attraction.
podAntiAffinity	Force node-api's 3 replicas onto distinct nodes. With required and 2 workers, one stays Pending forever — an important lesson about anti-affinity and replica counts. Switch to preferred and watch it schedule.
topologySpreadConstraints	maxSkew: 1 across kubernetes.io/hostname. The modern answer. Compare the failure mode: spread constraints degrade, required anti-affinity blocks.
taints + tolerations	Taint lab3-worker2 with dedicated=db:NoSchedule; tolerate it only on Postgres. You met this on the control-plane in 3.1 §2.6 — now you own one. Then try NoExecute and watch running Pods get evicted.
Part E — Node lifecycle and PodDisruptionBudget [PLAT]
The combination that matters. This is the rehearsal for every cloud node upgrade you will ever do.
	1. kubectl cordon lab3-worker2 — new Pods stop landing, existing ones stay. It's just spec.unschedulable: true.
	2. kubectl drain lab3-worker2 --ignore-daemonsets --delete-emptydir-data — watch eviction. Understand why both flags are needed and what happens without them. (You did this once in 3.1 §5.6; this time there's real state involved.)
	3. Add a PodDisruptionBudget: minAvailable: 2 for node-api at 3 replicas. Drain again. The drain now blocks, respecting your budget, and tells you exactly why.
	4. Set minAvailable: 3 at 3 replicas and drain. It blocks forever. This is the classic self-inflicted outage — an unsatisfiable PDB makes your cluster un-upgradable, and nothing tells you until upgrade night.
	5. uncordon, then observe Pods do not rebalance back. Kubernetes self-heals; it does not continuously optimise placement.
Part F (optional) — HPA [DEV] defines, [PLAT] enables
	• HPA v2 on node-api targeting 50% CPU utilisation. Note that "utilisation" is a percentage of requests — which is why Part A had to come first. A bad request value makes the HPA meaningless.
	• Load generator Pod hammering /burn?ms=200. Watch kubectl get hpa -w.
	• behavior.scaleDown.stabilizationWindowSeconds — the default 5-minute cooldown, and why scale-down is deliberately slower than scale-up (flapping).
	• Hit the ceiling on purpose: set maxReplicas above what 2 workers can schedule. Pods go Pending. The HPA has no idea your cluster is full and will keep asking. On EKS, Karpenter or Cluster Autoscaler answers by adding nodes; on KinD, nothing does. This is the clearest possible illustration of the two-layer autoscaling model, and it's why cluster autoscaling is parked to the EKS lab rather than faked here.
Checkpoint
You can explain why required podAntiAffinity with 3 replicas and 2 nodes is a bug, and what you'd use instead. Your resource requests are based on measurement, not guesses.
[PARKED]
The full affinity ladder (nodeName, nodeAffinity required vs preferred, weighted preferences, matchExpressions operators). ResourceQuota and LimitRange for namespace governance — genuinely useful, but it's multi-tenancy work and you have one tenant. Priority classes and preemption. Descheduler for rebalancing after uncordon. VPA (adjusts requests instead of replicas; conflicts with HPA on the same resource). KEDA for event-driven scaling on queue depth or Kafka lag.

Sub-lab 3.7 — Batch and scheduled work
Primary role: [DEV], almost entirely. The shortest sub-lab here, and a good one to slot in when you want a lighter session. The cleanup script gives Jobs an honest reason to exist rather than a contrived one.
Planned steps
	• Build the maintenance/cleanup image; kind load it.
	• Run it as a plain Job. The Pod goes to Completed, not Running. Note that it sticks around so you can read its logs — the opposite of docker run --rm, and a deliberate design choice.
	• restartPolicy: Jobs accept OnFailure or Never, never Always. Reason it out — Always would mean the Job can never complete, contradicting the definition. Then see the practical difference: OnFailure restarts the container in place (you lose the failed container's logs); Never creates a new Pod per attempt (you keep every attempt). For anything you'll need to debug, Never is usually right.
	• backoffLimit — make the script exit 1, watch exponential-backoff retries, then the Job go Failed.
	• activeDeadlineSeconds — make the script hang, watch the Job get killed. "Retried 6 times" and "took too long" are two different fields with two different failure reasons.
	• ttlSecondsAfterFinished: 300 — watch the Job garbage-collect itself. Without this, finished Jobs accumulate in etcd forever, which is a real operational problem in clusters with busy CronJobs.
	• completions + parallelism — run 4 completions with parallelism 2 to see the work-queue shape, even though your script doesn't need it.
	• Convert to a CronJob on */10 * * * *: 
		○ concurrencyPolicy: Allow | Forbid | Replace — make the script sleep 15 minutes on a 10-minute schedule and observe all three. Allow is the default and is almost always wrong for a cleanup job.
		○ successfulJobsHistoryLimit / failedJobsHistoryLimit — how much evidence you keep.
		○ timeZone — without it, CronJobs run in the controller-manager's timezone, which is UTC, which is not where your maintenance window is.
		○ suspend: true — the "stop it now without deleting it" switch.
	• kubectl create job --from=cronjob/heartbeat-cleanup manual-1 — trigger on demand. You will use this constantly.
Verification
Heartbeat row counts grow between runs and drop right after each execution. Then break it: wrong DB credentials in the Job. Diagnose with 3.4's loop, and notice the failed Job's logs live in a Pod you have to go find by label — which is a small preview of why log shipping exists.
[PARKED]
completionMode: Indexed and JOB_COMPLETION_INDEX — the primitive behind sharded batch work. startingDeadlineSeconds and the >100-missed-schedules failure mode. podFailurePolicy. Real work queues with an external broker.

Sub-lab 3.8 — Identity, permissions, and workload hardening
Primary role: [PLAT] for RBAC, [DEV] for securityContext, one [SRE] aside. v1 had all of this as "optional, lower priority." It isn't — it's the first thing you hit on any shared or real cluster, and on EKS it's the foundation for IRSA / Pod Identity. No rebuild required for any of this.
Part A — Every Pod already has an identity [PLAT]
	• kubectl get pod X -o jsonpath='{.spec.serviceAccountName}' → default. You never asked for this.
	• Look at what the kubelet mounted at /var/run/secrets/kubernetes.io/serviceaccount/. Note it's a projected, time-limited, audience-bound token now, not the legacy long-lived Secret. Look at kubectl get pod X -o yaml and find the projected volume you didn't write.
	• Set automountServiceAccountToken: false on all five app Deployments. None of them call the Kubernetes API, so none should carry a credential for it. Cheapest real security win in the entire lab.
Part B — Build the RBAC model deliberately [PLAT]
	• A dedicated ServiceAccount pod-reader-sa.
	• A Role granting get, list, watch on pods in multi-service-app.
	• A RoleBinding connecting them.
	• A debug Pod using that ServiceAccount.
	• From inside that Pod, curl the API server by hand using the mounted token and CA bundle. Do this once. It demystifies everything about in-cluster auth, and it connects straight back to 3.1 §3.6's "the API server is the only front door."
	• kubectl auth can-i — the command that answers RBAC questions in one second instead of thirty minutes: 
		○ kubectl auth can-i list pods --as=system:serviceaccount:multi-service-app:pod-reader-sa -n multi-service-app → yes
		○ same for secrets → no
		○ same for pods in -n default → no. This is the Role vs ClusterRole boundary, made visible.
		○ kubectl auth can-i --list --as=... for the full picture.
	• Role vs ClusterRole vs the binding combinations. The one that surprises people: a ClusterRole bound by a RoleBinding grants those permissions only in that namespace. That's the standard pattern for reusing built-in roles per-namespace.
	• Read the built-ins: kubectl get clusterroles | grep -v '^system:', then look at view, edit, admin, cluster-admin. Note that view deliberately excludes Secrets and edit does not — which tells you something about how people actually get owned.
Part C — Workload hardening [DEV]
	• Finish the securityContext pass: add readOnlyRootFilesystem: true to the four you already hardened in the retrofit.
	• This will break nginx and possibly Postgres. Fix with emptyDir mounts at the specific paths that need writes (/var/cache/nginx, /tmp, /var/run). It's fiddly, and that's the point — this is exactly the work involved in hardening a real deployment, and it's why most people skip it.
	• Pod Security Admission [PLAT]: label the namespace pod-security.kubernetes.io/enforce=restricted. If Part C was done properly, nothing breaks. Then submit a privileged Pod and read the rejection. Try warn and audit modes to see the non-blocking variants — which is how you'd roll this out on a cluster with existing workloads you can't break.
	• Try hostNetwork: true and privileged: true and confirm both are refused. Then work out what each would have given an attacker.
Part D — The Secrets reality check [SRE] aside, [PLAT] conclusion
You already did most of this in 3.2 §2.2, including the encryption-provider-config check that returned 0. Extend it once:
	• Read the Secret straight out of etcd inside the control-plane node with etcdctl. Unencrypted at rest, confirmed at the storage layer rather than inferred. Ten minutes, and it makes 3.2's lesson permanent.
	• Note who can read it: anyone with get secrets in the namespace, and anyone who can create a Pod that mounts it. That second one is the part people miss, and it means RBAC on pods/create is effectively RBAC on Secrets.
	• The conclusion: the actual control is RBAC plus encryption-at-rest, not the encoding. Enabling encryption-at-rest is [SRE] work that EKS does for you via KMS, which is why it's parked rather than built.
Checkpoint
kubectl auth can-i list secrets --as=system:serviceaccount:multi-service-app:pod-reader-sa -n multi-service-app returns no. PSA restricted is enforced and nothing is broken. All five Deployments have automountServiceAccountToken: false.
[PARKED] — including NetworkPolicy
NetworkPolicy is parked, and here's the honest reason. kindnet assigns Pod IPs and routes cross-node traffic but does not enforce NetworkPolicy. Writing policies on your current cluster would give you accepted objects that block nothing — worse than skipping the exercise, because you'd conclude it worked. Enforcement needs Calico or Cilium, which needs disableDefaultCNI: true, which needs a rebuild. You've asked not to rebuild, and that's the right call while 3.2 is working.
The workaround when you want it later, no rebuild:
docker stop lab3-control-plane lab3-worker lab3-worker2   # free the RAM, keep the cluster
kind create cluster --name netpol --config netpol-kind.yaml   # 1 CP + 1 worker, disableDefaultCNI
# install Calico, do the whole exercise, then:
kind delete cluster --name netpol
docker start lab3-control-plane lab3-worker lab3-worker2   # lab3 comes back exactly as it was
This also teaches kubectl config use-context juggling across clusters, which is a genuinely useful daily skill.
What the exercise would cover: proving the default is allow-all between all Pods in all namespaces — the exact opposite of Docker's custom-bridge default from Lab 02, and the single most important fact about Kubernetes networking. Then default-deny-ingress, watching the whole app break, and rebuilding connectivity explicitly to recreate Lab 02's three-network segmentation. Then default-deny-egress, which breaks DNS because CoreDNS is in another namespace — fixing that teaches more about NetworkPolicy than the ingress rules do. And the limits: NetworkPolicy is L3/L4 only. It cannot express "only GET requests" or "only if authenticated." That gap is the honest reason service meshes exist.
Also parked: encryption-at-rest configuration [SRE]. External Secrets Operator / Sealed Secrets / SOPS — deferred to the EKS and GitHub Actions labs where a real secret store and a real pipeline exist. Admission control beyond PSA (Kyverno, OPA Gatekeeper) — the next layer once PSA isn't expressive enough. Audit logging [SRE]. IRSA / EKS Pod Identity, which is where this sub-lab's RBAC work becomes load-bearing.

Sub-lab 3.9 — Stateful workloads and storage lifecycle
Primary role: [DEV] writes the StatefulSet, [PLAT] owns the storage. This also retires the strategy: Recreate workaround you had to use in 3.2 §6.3 — that hack exists precisely because a Deployment is the wrong controller for this workload, and now you get to fix it properly.
	Note on data. Converting to a StatefulSet with volumeClaimTemplates creates a new PVC (postgres-data-postgres-db-0), so you'll start with an empty database. Fine for a lab — your heartbeat tables refill in seconds. Keep the old postgres-pvc around until you're satisfied, then delete it deliberately. This is not a cluster rebuild; nothing outside the namespace is touched.
Part A — Prove the Deployment is wrong [DEV]
Before converting, demonstrate the problem. Temporarily switch strategy back to RollingUpdate and scale the Postgres Deployment to 2. Both Pods try to mount the same ReadWriteOnce PVC. Watch what happens — either a Multi-Attach error if they land on different nodes, or two postgres processes attacking one data directory if they don't. Then scale back to 1 and recover.
Four minutes, and it's the "why." Skipping it makes StatefulSet feel like arbitrary ceremony.
Part B — The conversion [DEV]
	• Headless Service first — clusterIP: None. Understand what it does: no ClusterIP, no kube-proxy involvement, DNS returns Pod IPs directly. StatefulSets require one for stable per-Pod DNS. Compare nslookup postgres-db before and after — this is a concrete extension of 3.2 §11's DNS work.
	• StatefulSet with volumeClaimTemplates instead of a shared PVC. One PVC per replica, created automatically, named deterministically.
	• Observe the four guarantees a Deployment never gives you: 
		○ Stable names: postgres-db-0, not postgres-7f8d9c-x4k2p.
		○ Stable per-Pod DNS: postgres-db-0.postgres-db.multi-service-app.svc.cluster.local.
		○ Ordered lifecycle: scale to 3 and watch -0, then -1, then -2, each waiting for the previous to be Ready. Scale down and watch -2 go first.
		○ Sticky storage: delete postgres-db-0 and watch the replacement bind the same PVC. This is the whole point, and it's a direct upgrade of 3.2 §12.4's persistence test.
	• Update DB_HOST in python-api-config (and node-api's) to the new Service name. Note that this is the "the name is load-bearing" lesson from 3.2 §7.1, biting for real.
	• podManagementPolicy: Parallel — the escape hatch when you don't need ordering. Try it, see the difference, set it back.
Part C — Storage lifecycle [PLAT]
Where the surprises live.
	• kubectl describe storageclass standard — note reclaimPolicy: Delete and volumeBindingMode: WaitForFirstConsumer. You met the second one as a "gotcha" in 3.2 §5; now see it as a deliberate design for node-local storage, and note that EBS behaves the same way for AZ reasons.
	• Delete the StatefulSet and watch the PVCs survive. By design. Which means "delete and redeploy" does not reset your database, and reclaiming that space is a separate, deliberate act. This surprises people in production.
	• persistentVolumeClaimRetentionPolicy (whenDeleted / whenScaled) — the newer field that lets you opt into cleanup. Set whenScaled: Delete, scale down, watch the PVC go.
	• reclaimPolicy: Retain vs Delete — create a StorageClass with Retain, use it, delete the PVC, and look at the orphaned Released PV holding your data hostage until you release it manually. The difference between "recoverable" and "gone."
	• Access modes — ReadWriteOnce, ReadOnlyMany, ReadWriteMany, ReadWriteOncePod. Note that local-path and EBS only do RWO, that RWX needs a network filesystem (EFS/NFS), and that this constraint shapes architecture — it's a large part of why you run one Postgres and not three.
	• Check allowVolumeExpansion on the StorageClass, try to grow a PVC, and note that shrinking is never supported anywhere.
Checkpoint
postgres-db-0 has a stable name and its own PVC. You've deleted the Pod and watched the replacement reattach the same volume. You can explain why strategy: Recreate was necessary before and is unnecessary now.
[PARKED]
pg_dump backup + destroy + restore, with a marker row to prove it — genuinely valuable, and honestly a DBA-flavoured detour for now. Do it the day before you put anything real on a cluster. updateStrategy.partition for StatefulSet canaries — obscure and useful. CloudNativePG and the operator comparison, deferred to the EKS lab where operators are unavoidable anyway. CSI driver internals. RWX with an NFS provisioner.

Sub-lab 3.10 — Packaging: Kustomize and Helm
Primary role: [PLAT], entirely. This is the bridge to the GitHub Actions lab, and arguably the most directly career-relevant sub-lab of the eight. You now have ~30 YAML files with hardcoded values and a future EKS lab that needs the same app with different values. This is the difference between that being a config change and a rewrite.
Part A — Kustomize (built into kubectl)
	• Restructure into base + overlays:
~/lab3/
├── base/
│   ├── kustomization.yaml
│   ├── postgres-statefulset.yaml
│   ├── python-api-deployment.yaml
│   └── ...
└── overlays/
    ├── kind/     # 1 replica, standard SC, NodePort 30080
    └── eks/      # 3 replicas, gp3 SC, LoadBalancer

	• kubectl apply -k overlays/kind — the entire app, one command.
	• configMapGenerator — and the loop this closes. In 3.2 §13 you edited a ConfigMap and watched the running Pod ignore it. configMapGenerator appends a content hash to the ConfigMap's name and rewrites every reference. Change a value → new name → the Pod template changes → Kubernetes rolls it automatically. That gotcha wasn't a quirk to work around; it was a signal you were missing a layer. Verify by editing DB_CONNECT_TIMEOUT again and watching a rollout you didn't ask for.
	• secretGenerator — same mechanism for Secrets, plus envs: sourcing from a .env file. Direct continuation of Lab 02's .env / .env.example / .gitignore discipline.
	• Patches: patches with strategic merge for structural changes, JSON 6902 for surgical ones (replace /spec/replicas). Learn when each is right.
	• images: transformer — override tags per overlay without touching base. This is exactly what a CI pipeline does on every commit, and it's the specific hook the GitHub Actions lab plugs into.
	• namePrefix / commonLabels — deploy two isolated copies of the whole app in one namespace, just to see it work.
	• kubectl kustomize overlays/kind to render without applying, and kubectl diff -k before every apply. Make both reflexes.
	• Break it: patch a field that doesn't exist. Kustomize happily produces YAML the API server then rejects — client-side rendering does not validate against your cluster's schema.
Part B — Helm: consuming other people's software
You already have metrics-server installed; do the next one properly with Helm and actually use the mechanics.
	• helm repo add / helm search repo / helm show values — read the values file before installing. This is 90% of real Helm use.
	• helm install --values my-values.yaml with a small, deliberate override.
	• helm template — render locally and read the output. This is how you find out what a chart is about to do to your cluster, and it's the step almost everyone skips.
	• helm upgrade, helm history, helm rollback — change a value, upgrade, roll back, confirm. Helm keeps release history in the cluster as Secrets in the release namespace. Go look at them; it's a nice illustration of "everything is an API object."
	• --atomic --wait --timeout — the flags that turn a half-applied upgrade into an automatic rollback. Non-negotiable in CI, and another direct GitHub Actions hook.
	• helm get manifest / helm get values — what's deployed vs what you asked for.
	• The comparison to write down (it's an interview question and a real decision):
		Kustomize	Helm
	Mechanism	overlay/patch real YAML	Go text templating
	Learning cost	low	moderate; templating a whitespace-sensitive format is genuinely unpleasant
	Parameterisation	anything you thought to patch	only what the chart author exposed
	Release lifecycle	none — it's just apply	install/upgrade/rollback/history, first-class
	Reading someone else's	easy, it's YAML	hard, it's templates
	Best at	your own app across environments	distributing software to strangers
No winner. Most mature setups use Kustomize for their own manifests and Helm for third-party software — which is exactly what you'll have done.
Part C — Retire kind load
	• Run a local registry container, wire it into the KinD cluster (the documented containerd config patch plus a local-registry-hosting ConfigMap — note this can be done on a running cluster by editing the containerd config inside each node and restarting containerd, no rebuild needed). Push your five images; point manifests at localhost:5000/....
	• kind load docker-image is now gone from your workflow. Rolling a new image is docker push + kubectl rollout restart — which is what CI does. The GitHub Actions lab becomes a registry hostname change rather than a redesign.
	• Set imagePullPolicy deliberately per environment, and understand the :latest special case (it implies Always, one of several reasons :latest is banned).
Part D — The completeness test (optional but recommended)
Now that it's cheap: kubectl delete namespace multi-service-app, then kubectl apply -k overlays/kind. Write down everything that didn't come back. Common misses: the namespace itself, the context default, Secrets created imperatively with kubectl create secret, the Gateway API CRDs, the registry config.
Every gap is something that would have broken a real disaster recovery. The cluster is untouched throughout — this is a namespace-level test, not a rebuild.
Checkpoint
kubectl apply -k overlays/kind restores the entire app from nothing. Editing one overlay value triggers a rollout automatically. You can articulate when you'd reach for Helm instead of Kustomize.
[PARKED]
Authoring your own Helm chart (Chart.yaml, helpers.tpl, conditionals, NOTES.txt) — do it if you ever need to distribute software. GitOps with Argo CD or Flux — belongs in the GitHub Actions lab as a push-vs-pull architecture decision. Server-side apply and field ownership. helm-diff and helmfile. Chart testing and ct lint.

Closing deliverable — the EKS gap ledger
Not a sub-lab. One page you write at the end of 3.10, as the input to the Terraform/EKS lab.
What you built on KinD	What happens on EKS	Effort
extraPortMappings + NodePort 30080	Doesn't exist. type: LoadBalancer provisions an NLB via the AWS Load Balancer Controller — which you install.	Medium
Ingress / Gateway API via Envoy Gateway	Works, but the idiomatic path is an ALB via the LB Controller's IngressClass.	Medium
standard / local-path StorageClass	Doesn't exist. EBS CSI driver (an EKS addon), gp3 StorageClass, and volumes become AZ-bound — which changes scheduling.	Medium
ReadWriteOnce was fine	Still RWO on EBS. RWX needs EFS + the EFS CSI driver.	Low
ServiceAccounts, no cloud identity	IRSA or EKS Pod Identity — a ServiceAccount annotated to assume an IAM role. Biggest new concept, and 3.8 is the prerequisite.	High
kind load → local registry	ECR, with IAM-based pull auth on the node role.	Low
kindnet	AWS VPC CNI by default — Pods get real VPC IPs. Changes NetworkPolicy, IP-exhaustion math, and security group behaviour entirely. Note NetworkPolicy still needs explicit enabling.	High conceptually
2 static workers	Managed node groups, or Karpenter provisioning on demand. This is what makes 3.6 Part F's HPA ceiling go away.	Medium
kubectl logs	Fluent Bit → CloudWatch Logs, or self-hosted Loki.	Medium
Secrets plaintext in etcd	KMS envelope encryption + External Secrets Operator.	Medium
kind create cluster	Terraform, VPC design, subnets, security groups, IAM, addons. This is the next lab.	The whole lab
cluster-admin in your kubeconfig	IAM → Kubernetes RBAC via access entries. 3.8's RBAC work is the prerequisite.	Medium
[SRE] etcd, certs, control-plane upgrades	AWS runs it. You never touch it.	Zero — this is what you're paying for
The reassuring half: every kubectl command, every manifest, your Kustomize overlays, RBAC, probes, PDBs, HPAs, StatefulSets, Jobs, graceful shutdown, and your entire triage table transfer unchanged. What changes is the infrastructure underneath — which is precisely the boundary Kubernetes exists to create, and you'll have spent eight sub-labs proving it holds.

Verification checklist
3.2 retrofits
	• [ ] [DEV] startupProbe present; the aggressive-liveness CrashLoop reproduced and understood.
	• [ ] [DEV] securityContext (4 fields) on both containers.
	• [ ] [DEV] Downward API surfacing node and Pod name via /api/info.
	• [ ] [DEV] Immutable ConfigMap rejection observed.
	• [ ] [DEV] Resource requests/limits present on both containers.
3.3 — entry point
	• [ ] [DEV] node-api and react-frontend running; the react-frontend manifest is visibly simpler and you can say why.
	• [ ] [PLAT] Ingress controller exposed on NodePort 30080, reachable from Windows.
	• [ ] [DEV] Ingress serves the whole app from one address; both status cards green.
	• [ ] [PLAT] Annotation typo silently misbehaves; pathType typo is rejected.
	• [ ] [PLAT] Gateway + [DEV] HTTPRoute serve the same routing.
	• [ ] [PLAT] Weighted canary split via backendRefs.
	• [ ] Can state the Ingress→Gateway API rationale in one sentence mentioning annotations.
3.4 — triage
	• [ ] All nine failures induced and diagnosed from symptoms alone, cold.
	• [ ] [DEV] kubectl debug used to get nslookup into a slim image.
	• [ ] [DEV] logs --previous used to read a dead container's output.
	• [ ] Failure #6 vs #7 distinction articulated (empty vs populated endpoints).
	• [ ] Written triage table produced.
3.5 — scale and rollout
	• [ ] [DEV] node-api at 3 replicas; /api/info rotates Pod and node.
	• [ ] [PLAT] maxSurge / maxUnavailable tuned; both trade-offs observed.
	• [ ] [PLAT] progressDeadlineSeconds exceeded, and confirmed it does not auto-rollback.
	• [ ] [DEV] Non-200s during rollout measured, then eliminated via preStop + SIGTERM handler + grace period.
	• [ ] [DEV] Short grace period + long preStop reproduced, errors returned.
3.6 — resources and scheduling
	• [ ] [PLAT] kubectl top working.
	• [ ] [DEV] Requests right-sized from measurement, not guesses.
	• [ ] [PLAT] Pod Pending on a 95%-idle node from requests alone.
	• [ ] [DEV] All three QoS classes produced; eviction order observed.
	• [ ] [PLAT] required anti-affinity with 3 replicas / 2 nodes leaves one Pending; preferred doesn't.
	• [ ] [PLAT] Self-authored taint repelling Pods; toleration overriding it.
	• [ ] [PLAT] drain blocked by a PDB, then an unsatisfiable PDB blocking it forever.
	• [ ] (Optional) HPA scales node-api under load, then hits a node-capacity ceiling.
3.7 — batch
	• [ ] [DEV] Cleanup Job runs once, then on a CronJob schedule; row counts drop after each run.
	• [ ] [DEV] OnFailure vs Never log-retention difference observed.
	• [ ] [DEV] backoffLimit exhaustion vs activeDeadlineSeconds timeout distinguished.
	• [ ] [DEV] All three concurrencyPolicy values observed with an overrunning job.
	• [ ] [DEV] ttlSecondsAfterFinished garbage-collecting a finished Job.
3.8 — identity and hardening
	• [ ] [PLAT] automountServiceAccountToken: false on all five app Deployments.
	• [ ] [PLAT] API server called by hand with a mounted ServiceAccount token.
	• [ ] [PLAT] auth can-i proves and disproves permissions, including across namespaces.
	• [ ] [PLAT] Can explain ClusterRole-bound-by-RoleBinding.
	• [ ] [DEV] readOnlyRootFilesystem: true everywhere, with emptyDir where needed.
	• [ ] [PLAT] PSA restricted enforced, nothing broken; privileged Pod rejected.
	• [ ] [SRE] Secret read directly out of etcd.
3.9 — stateful
	• [ ] [DEV] Two Postgres replicas on one RWO PVC demonstrated as broken (the "why").
	• [ ] [DEV] StatefulSet + headless Service; stable name postgres-db-0; per-Pod PVC.
	• [ ] [DEV] Pod deleted; replacement reattaches the same volume.
	• [ ] [DEV] Ordered create/delete observed; Parallel compared.
	• [ ] [PLAT] PVCs surviving StatefulSet deletion; Retain orphan observed.
	• [ ] [DEV] Can explain why strategy: Recreate is no longer needed.
3.10 — packaging
	• [ ] [PLAT] kubectl apply -k overlays/kind deploys the whole app.
	• [ ] [PLAT] configMapGenerator hash triggers an automatic rollout — 3.2's gotcha closed.
	• [ ] [PLAT] Separate kind and eks overlays differing in replicas, StorageClass, Service type.
	• [ ] [PLAT] A chart installed, upgraded, and rolled back with helm history inspected.
	• [ ] [PLAT] helm template output read before installing.
	• [ ] [PLAT] Local registry replacing kind load.
	• [ ] [PLAT] Kustomize-vs-Helm comparison written.
	• [ ] (Optional) Namespace deleted and fully restored; gaps written down.
Closing
	• [ ] EKS gap ledger written.

Sequencing
3.3 ──▶ 3.4 ──▶ 3.5 ──▶ 3.6
                          │
3.9 ─────────────────────┐│
                         ▼▼
                        3.10  ◀── everything funnels here
3.8 (independent) ───────┘
3.7 (independent, short — slot in anywhere)

	• 3.4 before 3.5 — you want the triage reflex before you start inducing rollout failures.
	• 3.6 before 3.5's HPA part — the HPA is meaningless until requests are measured.
	• 3.9 before 3.10 — Kustomize should be templating your final manifests, not ones you're about to replace.
	• 3.8 is fully independent — good session if you want a change of pace.
	• 3.10 last, always. It packages everything above it.
Role coverage on completion
	Coverage	Honest assessment
[DEV]	~95%	Solid. You could join a team shipping to an existing cluster and be useful on day one.
[PLAT]	~70%	Competent. The gaps are cloud-shaped (IRSA, managed ingress, autoscaling, secret stores) and all close in the EKS lab. Plus NetworkPolicy and observability, both parked with a clear path back.
[SRE]	~10%, deliberately	Correct for this path. EKS sells you etcd, certificates, and control-plane upgrades. Revisit only for the CKA.
The honest target this plan hits: competence. You can deploy, debug, and operate a real app on Kubernetes unsupervised, and when it breaks you have a procedure rather than a feeling. That's what makes the eventual production incidents teach you instead of just hurting — and it's what gets you to GitHub Actions and Terraform this quarter instead of next year.

From <https://claude.ai/chat/2315662e-56c6-41a7-93c6-4843bbdeee96> 
