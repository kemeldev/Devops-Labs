Lab 3.3 — Completing the Translation & the Entry Point
Detailed walkthrough — builds on the lab3 KinD cluster from Sub-lab 3.1 and the Postgres + python-api stack from Sub-lab 3.2.
By the end of this sub-lab, all five Lab 02 services run on Kubernetes and the whole app is reachable from your Windows workstation through a single address, with kubectl port-forward retired for good. You'll build the entry point twice — once with Ingress, once with Gateway API — and the difference between those two experiences is the real payload of the sub-lab.

Decision: no ingress-nginx, and the precise reason
Your instinct was right, but let's be exact about what's retired, because the distinction matters and it's the kind of thing people get wrong in interviews.
Thing	Status
Ingress — the API object (networking.k8s.io/v1)	Stable and fine. Not deprecated. It is in every cluster you will ever touch and in thousands of existing repos. You must be able to read and write it.
ingress-nginx — one particular controller	Retired. Kubernetes SIG Network ended maintenance in March 2026. No further releases, no bugfixes, no CVE patches. The project's own README now tells new users to deploy something else.
Gateway API (gateway.networking.k8s.io)	The successor API. Standard channel is stable for HTTPRoute.
So "don't use ingress-nginx" doesn't mean "skip Ingress." It means use a maintained controller. This lab uses Traefik v3, which implements both the Ingress API and the Gateway API in one install.
Why one controller for both passes, rather than the two-controller setup in the plan:
	• The comparison becomes honest. When Ingress and Gateway API run on the same data plane, every difference you observe is a difference in the API, not a difference between two vendors' proxies. That's the lesson you're after.
	• Half the RAM. Your host is tight, and 3.6 adds metrics-server on top.
	• Traefik is genuinely one of the controllers you'll meet in the wild, and it has a documented compatibility layer for ingress-nginx annotations — which makes it the realistic migration target for a real 2026 job task.
Bonus lesson you get for free: Traefik cannot strip a path prefix with an annotation alone. It needs a Middleware custom resource, referenced by annotation. So the "annotations aren't portable" warning stops being abstract — you'll see with your own eyes that moving from nginx to Traefik means rewriting your routing config, not just editing a string.

Role tags
Tag	Meaning
[DEV]	Application developer on Kubernetes. Workload manifests, routes for your own app.
[PLAT]	Platform / DevOps engineer. The controller, the Gateway, cluster-wide plumbing. Your target role.
[SRE]	Control-plane administration. Almost none in this sub-lab.
This sub-lab is the clearest illustration of the DEV/PLAT boundary in all of Kubernetes, and Gateway API encodes that boundary directly into its object model. Watch for it in Step 7.

How to use this guide
Same as 3.1 and 3.2. Every step has:
	• Run — the exact commands.
	• Expect — what a correct result looks like, so you can tell "worked" from "silently didn't."
	• Why it matters — the mental-model payload.
Sections marked [Deep dive] are optional in the sense that the checklist doesn't require them, and not optional in the sense that they're what makes 3.4's triage exercises debuggable.
Convention: $ = command on the Ubuntu host over SSH. PS> = command on your Windows workstation.

Step 0 — Pre-flight
Ten minutes here saves an afternoon. Three of these five checks catch problems that present as "the ingress doesn't work" and aren't the ingress.
0.1 — Confirm 3.2 is still healthy
bash
kubectl config current-context          # kind-lab3
kubectl config view --minify | grep namespace:   # multi-service-app
kubectl get pods -o wide
kubectl get svc
kubectl get pvc
Expect: postgres and python-api both 1/1 Running with RESTARTS 0, Services postgres-db and python-api, PVC postgres-pvc Bound.
If RESTARTS is climbing, stop and fix that first — 3.3 adds three more moving parts and you do not want to debug two problems at once. That principle is the whole reason this lab is split into sub-labs.
0.2 — Check resources
bash
free -h
docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'
df -h /
Expect: you want at least 2 GB free before starting. Traefik itself is light (~100 MB), but you're about to add two more app Deployments plus a build.
0.3 — Gather the facts you'll need
Write these down. Every routing bug in this sub-lab traces back to one of them being wrong.
bash
# What port does python-api's Service expose, and what does it target?
kubectl get svc python-api -o jsonpath='{.spec.ports[0]}' | python3 -m json.tool
# What's the app's real container port?
kubectl get deploy python-api -o jsonpath='{.spec.template.spec.containers[0].ports}' | python3 -m json.tool
# What paths does the app actually serve?
kubectl port-forward svc/python-api 8080:80 >/dev/null 2>&1 &
#The final & starts kubectl port-forward in the background. If it is the first background job in that shell, Bash assigns it job number [1].
sleep 2
curl -s http://localhost:8080/health | python3 -m json.tool
curl -s http://localhost:8080/api/db | python3 -m json.tool
kill %1
Expect: Service port: 80, targetPort: http; container port named http. App serves /health, /api/info, /api/db.
Record this table for yourself — you'll refer to it in Steps 6 and 7:
Service	Service port	Container port	App paths
python-api	80	http (8001)	/health, /api/info, /api/db
node-api	80	http (8002)	/health, /api/info, /api/db
react-frontend	80	http (80)	/ and static assets
0.4 — Confirm the frontend's baked-in API URLs
This is the single most likely thing to make Step 8's status cards stay red, and it is not fixable after the fact — it's baked into the JS bundle at build time. Lab 02 §"the app" already flagged this; now it becomes load-bearing.
bash
cd ~/multi-service-App/frontend
grep -rn "VITE_PY_API\|VITE_NODE_API" src/ .env* 2>/dev/null
	-r — Searches recursively through files and subdirectories under src/.
	-n — Shows the matching line number.
	
You need the built bundle to call relative paths — /api/py and /api/node — not absolute URLs with a host in them. If your Lab 02 image was built with VITE_PY_API=/api/py, you're fine. If it has a hostname or a port in it, you must rebuild in Step 3.
Why it matters: the browser downloads that JS and executes it on your workstation. If the bundle says http://172.31.17.182:8001, the browser tries to reach a container port that no longer exists and you get a CORS error or a connection refusal. If it says /api/py, the browser calls back to whatever origin served the page — which is your Ingress — and CORS never enters the picture because it's the same origin. That's the entire reason the path-based routing design works.
0.5 — The host firewall (do not skip)
You are about to expose port 30080 on the Ubuntu host. Check what's in the way.
bash
sudo ufw status verbose
sudo ss -tulpn | grep -E ':30080|:30443'
If ufw is active and 30080 isn't allowed:
bash
sudo ufw allow from 172.31.16.0/22 to any port 30080 proto tcp comment 'lab3 traefik http'
sudo ufw allow from 172.31.16.0/22 to any port 30443 proto tcp comment 'lab3 traefik https'
sudo ufw status numbered
Scoped to the /22, exactly as Lab 01 Step 2 scoped port 80. Not 0.0.0.0/0.
	[Deep dive] — the Docker/ufw trap, which is a real security lesson.
	Test 30080 before and after adding that rule. You may find it was already reachable without it.
	That's because Docker publishes ports by writing DNAT rules into iptables' nat table and accept rules into its own DOCKER chain in FORWARD — which is traversed before and separately from ufw's rules in INPUT. A published Docker port routinely bypasses ufw entirely.
	So ufw deny on a Docker-published port often does nothing at all. This surprises people badly on internet-facing hosts: they publish a database port "protected by ufw," and it isn't. The correct fixes are DOCKER-USER chain rules, or binding to a specific interface (-p 127.0.0.1:5432:5432).
	Your extraPortMappings in kind-lab3.yaml are plain Docker port publishing on the control-plane node container, so this applies to them directly. Add the ufw rules anyway — defence in depth, and correct if the mechanism ever changes — but know that they may not be what's actually letting traffic through.
0.6 — Working directory

mkdir -p ~/lab3/msa ~/lab3/traefik ~/lab3/broken
ls -l ~/lab3/msa
~/lab3/broken/ is for Step 9's deliberately-broken manifests. ~/lab3/traefik/ keeps platform-layer config separate from app manifests — a small habit that pays off in 3.10 when Kustomize wants a clean base/.

Step 1 — node-api: Deployment and Service [DEV]
This should feel mechanical. That's the point — you internalised the pattern in 3.2, and repetition is how it becomes muscle memory rather than a document you copy from.
1.1 — Build and load the image
bash
cd ~/multi-service-App/api-node
docker build -t node-api:0.1.0 .
docker images node-api
Now the moment 3.2 §1.3 warned you about:
# The host's Docker store — the image is here
docker images | grep node-api
# The cluster's containerd store — it is NOT here
docker exec lab3-worker crictl images | grep node-api || echo "  MISSING, as predicted"
Expect: present in Docker, missing in containerd.
Why it matters: this is the surprise 3.2 told you was coming. Two completely separate image stores on one host, with no connection between them. Building an image does not make it visible to the cluster. In a real cluster the bridge is a registry; in KinD it's kind load.
bash
kind load docker-image node-api:0.1.0 --name lab3
for n in lab3-control-plane lab3-worker lab3-worker2; do
  echo "== $n"
  docker exec "$n" crictl images | grep node-api || echo "   MISSING"
done
Expect: present on all three nodes. Slow, because it streams the whole image to each node separately.
1.2 — ConfigMap
bash
cat > ~/lab3/msa/09-node-api-config.yaml <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: node-api-config
  labels:
    app: node-api
data:
  DB_HOST: "postgres-db"
  DB_PORT: "5432"
  DB_NAME: "appdb"
  DB_SSL: "false"
  DB_CONNECT_TIMEOUT: "5"
EOF
kubectl apply -f ~/lab3/msa/09-node-api-config.yaml
kubectl get cm node-api-config -o jsonpath='{.data}' | python3 -m json.tool
Note DB_SSL: "false" — quoted. Same trap as 3.2 §3: ConfigMap values are strings, and an unquoted false is a YAML boolean, which the API rejects. Match your app's real variable names; the repo's README uses DB_SSL=false for the Node service specifically.
1.3 — Deployment
Note what's carried forward from the 3.2 retrofits: startupProbe, securityContext, resources, and the Downward API.
bash
cat > ~/lab3/msa/10-node-api-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: node-api
  labels:
    app: node-api
spec:
  replicas: 1
  selector:
    matchLabels:
      app: node-api
  template:
    metadata:
      labels:
        app: node-api
    spec:
      automountServiceAccountToken: false     # it never calls the K8s API
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
          securityContext:
            runAsNonRoot: true
            runAsUser: 70                     # 'postgres' in the alpine image
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
      containers:
        - name: node-api
          image: node-api:0.1.0
          imagePullPolicy: IfNotPresent        # required: kind-loaded, not in a registry
          ports:
            - name: http
              containerPort: 8002              # <-- VERIFY against your app
          envFrom:
            - configMapRef:
                name: node-api-config
          env:
            - name: DB_USER
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: username
            - name: DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: db-credentials
                  key: password
            # Downward API — makes 3.5's load-balancing exercise legible
            - name: POD_NAME
              valueFrom:
                fieldRef:
                  fieldPath: metadata.name
            - name: NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
            - name: POD_IP
              valueFrom:
                fieldRef:
                  fieldPath: status.podIP
          startupProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 3
            failureThreshold: 20               # up to 60s to start
          readinessProbe:
            httpGet:
              path: /health
              port: http
            periodSeconds: 5
            timeoutSeconds: 3
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /health
              port: http
              # no initialDelaySeconds — startupProbe handles the boot window
            periodSeconds: 15
            timeoutSeconds: 5
            failureThreshold: 3
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
          securityContext:
            runAsNonRoot: true
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
EOF
Before applying, verify the container port:
bash
docker run --rm node-api:0.1.0 sh -c 'grep -rn "listen\|PORT" /app 2>/dev/null | head' || true
grep -rn "listen(" ~/multi-service-App/api-node/*.js ~/multi-service-App/api-node/src/*.js 2>/dev/null | head
Then:
bash
kubectl apply -f ~/lab3/msa/10-node-api-deployment.yaml
kubectl rollout status deployment/node-api --timeout=120s
kubectl get pods -l app=node-api -o wide
Expect: 1/1 Running, RESTARTS 0, scheduled on a worker (never the control-plane — 3.1 §2.6's taint still at work).
	⚠️ Likely first failure: runAsNonRoot: true
	If the Pod goes to CreateContainerConfigError with a message about running as root, your Node image has no USER directive, or it declares a username rather than a numeric UID — Kubernetes can't resolve names, only numbers.
	bash
	kubectl describe pod -l app=node-api | sed -n '/Events:/,$p'
docker inspect node-api:0.1.0 --format '{{.Config.User}}'
	
	Two fixes. Best: add USER 1000 (numeric) to the Dockerfile and rebuild — carrying Lab 02's non-root discipline properly. Quick: add runAsUser: 1000 alongside runAsNonRoot in the manifest. Do the first one; it's ten seconds and it fixes the image rather than papering over it.
	The official node images provide a node user at UID 1000, so runAsUser: 1000 usually just works.
	I did the quick: 
	securityContext:
	            runAsNonRoot: true
	            runAsUser: 1000
	
1.4 — Verify the wiring
bash
POD=$(kubectl get pod -l app=node-api -o jsonpath='{.items[0].metadata.name}')
kubectl logs "$POD" -c wait-for-postgres
kubectl logs "$POD" --tail=30
kubectl exec "$POD" -- env | grep -E '^(DB_|POD_|NODE_)' | sort
kubectl describe pod "$POD" | sed -n '/Init Containers:/,/^Conditions:/p'
Expect: the init container State: Terminated, Reason: Completed, Exit Code: 0. Env shows five DB_* from the ConfigMap, two from the Secret, three POD_*/NODE_* from the Downward API — ten variables, three sources, one flat namespace. The container has no idea which came from where.
1.5 — Service
bash
cat > ~/lab3/msa/11-node-api-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: node-api
  labels:
    app: node-api
spec:
  type: ClusterIP
  selector:
    app: node-api
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
EOF
kubectl apply -f ~/lab3/msa/11-node-api-service.yaml
kubectl get svc node-api
kubectl get endpointslices -l kubernetes.io/service-name=node-api
Expect: a ClusterIP, and an EndpointSlice containing the Pod's IP on port 8002.
Note the reflex from 3.1 §4.5: populated EndpointSlice is the pass condition, not "the Service exists."
bash
kubectl run curl-test --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -sS -m 5 http://node-api/api/db; echo
Expect: JSON with db_status connected and a heartbeat count.

Step 2 — react-frontend: the interesting one [DEV]
2.1 — Rebuild with relative paths, if 0.4 said you need to
bash
cd ~/multi-service-App/frontend
docker build \
  --build-arg VITE_PY_API=/api/py \
  --build-arg VITE_NODE_API=/api/node \
  -t react-frontend:0.1.0 .
If your Dockerfile takes them as ENV rather than ARG, adjust — but the values must be those two relative paths.
Verify they actually got baked in. This is worth doing once, because the failure mode is silent:
bash
CID=$(docker create react-frontend:0.1.0)
docker cp "$CID":/usr/share/nginx/html/. /tmp/fe-check/ 2>/dev/null
docker rm "$CID" >/dev/null
grep -ro "/api/py\|/api/node\|172\.31\.\|localhost:800" /tmp/fe-check/assets/ 2>/dev/null | sort -u | head
rm -rf /tmp/fe-check
Expect: /api/py and /api/node present; no IP addresses, no localhost:800x. If you see the latter, the build args didn't take and Step 8's status cards will be red no matter how perfect your routing is.
bash
kind load docker-image react-frontend:0.1.0 --name lab3
for n in lab3-control-plane lab3-worker lab3-worker2; do
  docker exec "$n" crictl images | grep react-frontend || echo "$n MISSING"
done
2.2 — Deployment
bash
cat > ~/lab3/msa/12-react-frontend-deployment.yaml <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: react-frontend
  labels:
    app: react-frontend
spec:
  replicas: 1
  selector:
    matchLabels:
      app: react-frontend
  template:
    metadata:
      labels:
        app: react-frontend
    spec:
      automountServiceAccountToken: false
      containers:
        - name: nginx
          image: react-frontend:0.1.0
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 80              # or 8080 if your image runs unprivileged nginx
          readinessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 5
            failureThreshold: 3
          livenessProbe:
            httpGet:
              path: /
              port: http
            periodSeconds: 20
            failureThreshold: 3
          resources:
            requests:
              cpu: 10m
              memory: 32Mi
            limits:
              memory: 128Mi
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop: ["ALL"]
            seccompProfile:
              type: RuntimeDefault
EOF
kubectl apply -f ~/lab3/msa/12-react-frontend-deployment.yaml
kubectl rollout status deployment/react-frontend --timeout=90s
	⚠️ Two nginx-specific traps
	Port 80 needs root. The stock nginx:alpine image runs its master process as root to bind port 80, so runAsNonRoot: true breaks it. That's why it's absent above — and why nginxinc/nginx-unprivileged exists, which listens on 8080 and runs as UID 101. If Lab 02 used the unprivileged image, set containerPort: 8080.
	readOnlyRootFilesystem is deliberately absent. nginx writes to /var/cache/nginx, /var/run, and /tmp. Adding it now would break the Pod. Sub-lab 3.8 fixes this properly with emptyDir mounts, and the fiddliness is the lesson there. Don't fight it here.
2.3 — Service
bash
cat > ~/lab3/msa/13-react-frontend-service.yaml <<'EOF'
apiVersion: v1
kind: Service
metadata:
  name: react-frontend
  labels:
    app: react-frontend
spec:
  type: ClusterIP
  selector:
    app: react-frontend
  ports:
    - name: http
      port: 80
      targetPort: http
      protocol: TCP
EOF
kubectl apply -f ~/lab3/msa/13-react-frontend-service.yaml
kubectl get endpointslices -l kubernetes.io/service-name=react-frontend
kubectl run curl-test --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- \
  curl -sS -m 5 -o /dev/null -w '%{http_code}\n' http://react-frontend/
Expect: 200.
2.4 — Why it matters: read the asymmetry
Put the three manifests side by side:
bash
wc -l ~/lab3/msa/07-python-api-deployment.yaml \
      ~/lab3/msa/10-node-api-deployment.yaml \
      ~/lab3/msa/12-react-frontend-deployment.yaml

wc = word count command
-l = count lines only

react-frontend has no init container, no Secret, no ConfigMap, and no envFrom. It's roughly a third the size.
That asymmetry is information about the app's architecture, visible in the YAML. The frontend has no backing service dependency — it's static files. The APIs cannot start without a database. You could infer the entire dependency graph of this application from the manifests alone, without reading a line of source code.
That's a real skill. Landing on an unfamiliar repo, the manifests are frequently the fastest accurate description of how the system fits together — faster than the README, and unlike the README, they can't be out of date without the app being broken.

Step 3 — Checkpoint: five services, no entry point yet
bash
kubectl get deploy,pods,svc -o wide
kubectl get endpointslices
Pass conditions — all of them:
Check	Required
Deployments	4 (postgres, python-api, node-api, react-frontend), all 1/1
Pods	4, all 1/1 Running, RESTARTS 0
Services	4 ClusterIP, all with populated EndpointSlices
Pod spread	at least one Pod on each worker
Now prove the whole app works internally, before adding any routing:
bash
kubectl run curl-test --rm -it --image=curlimages/curl:8.10.1 --restart=Never -- sh -c '
  for svc in python-api node-api; do
    echo "== $svc"
    curl -sS -m 5 "http://$svc/health"; echo
    curl -sS -m 5 "http://$svc/api/db"; echo
  done
  echo "== react-frontend"
  curl -sS -m 5 -o /dev/null -w "HTTP %{http_code}\n" http://react-frontend/
'
Expect: both APIs healthy and DB-connected; frontend returns 200.
Why this checkpoint exists: if this passes and Step 6 fails, the problem is 100% in the routing layer. If you skip this, you'll be debugging two layers at once with no way to tell them apart. This is the same discipline as 3.2 §8, and it's the single habit that most reduces debugging time in Kubernetes.

Step 4 — Install Helm and Traefik [PLAT]

You cross the DEV/PLAT line here. Everything so far has been "my app." Everything in this step is cluster infrastructure that all apps share.

4.1 — Install Helm
Installing Helm | Helm

curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm -f get_helm.sh
helm version
echo 'source <(helm completion bash)' >> ~/.bashrc && source ~/.bashrc
A note on why Helm is here and not in 3.10. You're using Helm as a package installer — the tool that gets Traefik into your cluster. Sub-lab 3.10 teaches Helm as a skill: values files, upgrades, rollbacks, release history, templating. Installing a chart today and understanding the chart mechanism later is the normal order, and it's how most people actually learn it.
4.2 — Add the repo and read the values first
A Helm package is called a chart.


bash
helm repo add traefik https://traefik.github.io/charts
helm repo update
helm search repo traefik/traefik
Now the habit that matters more than any other in Helm:

helm show values traefik/traefik > ~/lab3/traefik/values-reference.yaml
wc -l ~/lab3/traefik/values-reference.yaml
grep -n -A 12 '^service:' ~/lab3/traefik/values-reference.yaml
grep -n -A 6  'kubernetesGateway' ~/lab3/traefik/values-reference.yaml
grep -n -B 2 -A 20 '^ports:' ~/lab3/traefik/values-reference.yaml | head -60
Expect: a file of a thousand-plus lines. Find service.type, ports.web.nodePort, ports.websecure.nodePort, providers.kubernetesGateway.enabled, and the gateway: block.
Why it matters: helm show values is the only documentation of what a chart will actually do that is guaranteed to match the version you're installing. Blog posts go stale, and chart values get renamed between major versions. Reading this file before installing is about 90% of real Helm usage. It is also the step almost everyone skips, right before they file a bug report.
	Chart drift warning. Traefik's chart has renamed values across major versions (v28 moved to Traefik v3; v34 split CRDs into a separate chart). If a key below doesn't appear in your values-reference.yaml, trust the file, not this document. Step 4.5 catches any mismatch before it reaches your cluster.
4.3 — Install the Gateway API CRDs 
Custom Resource Definition (CRD teaches Kubernetes a new object type.)
The Traefik chart manages its own CRDs but not the Gateway API ones — those belong to the Kubernetes project, not Traefik.

Kubernetes normally understands objects like:
Pod  Service  Deployment ConfigMap  Secret  Ingress
But Kubernetes may not automatically know about Gateway API objects like:
	• GatewayClass
	• Gateway
	• HTTPRoute
	• ReferenceGrant
So Step 4.3 installs CRDs.

bash
# Check the current release first — don't trust a pinned version in a document
# https://github.com/kubernetes-sigs/gateway-api/releases
GWAPI_VERSION=v1.6.1
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GWAPI_VERSION}/standard-install.yaml"
kubectl get crd | grep gateway.networking.k8s.io
kubectl api-resources | grep -i gateway
Expect: CRDs for gatewayclasses, gateways, httproutes, grpcroutes, referencegrants, backendtlspolicies.
Why it matters — connect this to 3.1 §3.6. You just ran kubectl api-resources and the catalogue is longer than it was five minutes ago. You extended the Kubernetes API by applying YAML. kubectl get httproutes now works, kubectl explain httproute.spec reads a live schema, RBAC can grant permissions on the new type, and objects you create will be stored in etcd exactly like a Pod.
This is your first CRD, and note how you got it: you installed software. That's how almost everyone meets their first CRD. Sub-lab 3.12 (parked) covers writing one; today the useful observation is that the mechanism exists and is this ordinary.
Standard vs Experimental channel: you installed Standard, which contains the stable, GA-level resources (HTTPRoute is v1). Experimental adds TCPRoute, TLSRoute, and in-progress features. Standard is correct here.
4.4 — Write the values file
Write the Traefik values file “Install Traefik, but with these custom settings for my lab.”
Install Traefik as the cluster entry point, expose it on host ports 30080 and 30443, and enable both Ingress and Gateway API support.

cat > ~/lab3/traefik/values.yaml <<'EOF'
# Traefik v3 for the lab3 KinD cluster.
# Exposed via NodePort on 30080/30443 to match kind-lab3.yaml's extraPortMappings.
deployment:
  replicas: 1
service:
  type: NodePort
ports:
  web:
    port: 8000          # port inside the container
    exposedPort: 80     # port on the Service
    nodePort: 30080     # port on every node  <-- matches extraPortMappings
    protocol: TCP
  websecure:
    port: 8443
    exposedPort: 443
    nodePort: 30443     # matches extraPortMappings
    protocol: TCP
    tls:
      enabled: true
providers:
  # Watch classic Ingress objects (Step 6)
  kubernetesIngress:
    enabled: true
  # Watch Traefik's own CRDs — needed for the Middleware in Step 6
  kubernetesCRD:
    enabled: true
  # Watch Gateway API objects (Step 7)
  kubernetesGateway:
    enabled: true
# The chart can create the Gateway object for us.
gateway:
  enabled: true
  listeners:
    web:
      port: 8000
      protocol: HTTP
      namespacePolicy:
        from: All        # <-- see 4.7; without this, cross-namespace routes are refused
logs:
  general:
    level: INFO
  access:
    enabled: true        # you will want this in Step 9
resources:
  requests:
    cpu: 50m
    memory: 64Mi
  limits:
    memory: 256Mi
EOF
Three fields deserve a hard look.
service.type: NodePort, not the chart default. The chart defaults to LoadBalancer, which on KinD stays <pending> forever because there's no cloud controller to provision one. NodePort is the correct choice here.
nodePort: 30080. This is the whole reason 3.1 declared extraPortMappings at cluster-creation time and flagged them as immutable. That decision, made two sub-labs ago before you had anything to route, is what lets you do this today without rebuilding the cluster. Read 3.1 §2.2's note again — this is the payoff.
namespacePolicy.from: All. Explained in 4.7; it's the single most likely reason Step 7 fails.
4.5 — Render before you install
Render means : “Helm, show me the Kubernetes YAML you would create if I installed Traefik.”
helm template traefik traefik/traefik \
  --namespace traefik \
  --values ~/lab3/traefik/values.yaml \
  > ~/lab3/traefik/rendered.yaml
wc -l ~/lab3/traefik/rendered.yaml
# Did our Service settings actually take?
awk '/^kind: Service$/,/^---/' ~/lab3/traefik/rendered.yaml | grep -E 'name:|type:|nodePort:|port:|targetPort:'
# Did the Gateway get created with the namespace policy?
awk '/^kind: Gateway$/,/^---/' ~/lab3/traefik/rendered.yaml
Expect: type: NodePort and nodePort: 30080 / nodePort: 30443 in the Service; a Gateway with from: All.
	If type is still LoadBalancer or the nodePorts are absent, stop. Your chart version uses different keys. Grep values-reference.yaml for the right path (some versions nest it as service.spec.type), fix values.yaml, and re-render. Do not install and then debug in the cluster — that's how you end up with a half-configured release and no idea which layer is wrong.
Why it matters: helm template renders the chart locally and sends nothing anywhere. It is how you find out what a chart is about to do to your cluster before it does it. It also makes chart-version drift a thirty-second problem instead of an hour-long one, which is exactly the situation you're in with a document written at a different time than your helm repo update.
4.6 — Install
bash
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  --values ~/lab3/traefik/values.yaml \
  --wait --timeout 3m
helm list -n traefik
kubectl get all -n traefik

Expect: the release deployed, one Traefik Pod 1/1 Running, a Service of type NodePort with 80:30080/TCP and 443:30443/TCP.
Note --wait --timeout — Helm blocks until resources are actually ready rather than returning the instant the API accepts the objects. In CI you'd add --atomic so a failed install rolls itself back. Sub-lab 3.10 covers those flags properly.

Here i faced and issue:
During Step 4.6, the Traefik Helm install failed with: Error: INSTALLATION FAILED: context deadline exceeded
Helm marked the release as failed because the Traefik Service was still created as:
	• TYPE: LoadBalancer
	• EXTERNAL-IP: <pending>
In a KinD cluster, LoadBalancer Services usually stay in <pending> because there is no cloud load balancer available.

Root cause: The lab instructions used this value: 
	• service:
	•   type: NodePort
But the installed Traefik Helm chart version did not use that key path. The chart ignored it and kept the default Service type as LoadBalancer
Fix
The Service type needed to be configured using the chart’s expected structure:
	• service:
	•   spec:
	•     type: NodePort
Then traefik was unistall, the chart was re-renderd and installed back again
Always run helm template before installing a chart. It shows the actual Kubernetes YAML Helm will create. In this case, it revealed that the chart ignored service.type: NodePort and still rendered a LoadBalancer Service.

This happened because of Helm chart version drift: different Traefik chart versions may use different value paths


4.7 — Verify the four objects Traefik created
bash
# 1. The controller Pod — note WHICH node
kubectl get pods -n traefik -o wide
# 2. The Service, with your nodePorts
kubectl get svc -n traefik
# 3. The IngressClass — Step 6 references this by name
kubectl get ingressclass
kubectl describe ingressclass traefik
# 4. The GatewayClass and Gateway — Step 7 uses these
kubectl get gatewayclass
kubectl get gateway -n traefik
kubectl describe gateway -n traefik
Expect: GatewayClass traefik with ACCEPTED: True; the Gateway PROGRAMMED: True.
	The question worth stopping on
	The Traefik Pod is almost certainly on lab3-worker or lab3-worker2. Your host port mappings are on lab3-control-plane. So how does traffic arriving at the control-plane node reach a Pod on a different node?
	kube-proxy. A NodePort is programmed into the iptables/nftables rules of every node in the cluster, including the control-plane, including nodes that hold no Pod for that Service. A packet hitting lab3-control-plane:30080 is DNAT'd by kube-proxy to a live Pod IP wherever it lives, and kindnet routes it across the node boundary.
	This is exactly the component you defined in 3.1 §3.2 as "programs iptables/nftables rules so traffic to a Service's ClusterIP is DNAT'd to a real Pod IP" — and here it is, doing that job for real, on the critical path of your app.
	Contrast this with hostPort. The ingress-nginx KinD manifest uses hostPort: 80 plus a node selector, which binds the port directly on one specific node's network namespace, bypassing kube-proxy entirely. That's why it needs the controller pinned to the node whose ports are mapped. NodePort has no such requirement — it works from any node, and the controller can be scheduled anywhere or rescheduled at any time.
	Verify it yourself:
	bash
	kubectl get pods -n traefik -o jsonpath='{.items[0].spec.nodeName}'; echo
docker exec lab3-control-plane iptables-save -t nat 2>/dev/null | grep 30080 | head -5
4.8 — Reach it from the host, then from Windows
bash
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/
Expect: 404. That is success. Traefik is listening, the port mapping works, kube-proxy is routing — and no route matches / yet because you haven't written one. A 404 from Traefik means the whole chain works and only the routing rules are missing.
If you get Connection refused instead, the problem is the port chain, not routing. Jump to Troubleshooting.
From Windows:
powershell
PS> curl.exe -v http://172.31.17.54:30080/
Expect: the same 404. If the host gives 404 and Windows gives a timeout, it's ufw or network — go back to §0.5.

Step 5 — Ingress: the literacy pass [PLAT] to enable, [DEV] to route
5.1 — Why you need a Middleware CRD, not an annotation
In Lab 02, nginx.pathbased.conf used a rewrite rule to remove the path prefix.

With ingress-nginx, you could do this using the nginx.ingress.kubernetes.io/rewrite-target annotation and a regular expression. Traefik does not support this annotation and may ignore it without displaying an error.

In Traefik, removing a path prefix requires a Middleware object. You must then connect that Middleware to the route using a Traefik-specific annotation.
The main lesson is that annotations are not portable between ingress controllers. Migrating from ingress-nginx to Traefik requires more than changing an annotation value. You must create a Traefik-specific resource and update the annotation that references it.

In Step 7, you will configure the same path rewrite using the Gateway API. This approach uses a short, structured, and validated configuration without controller-specific annotations or custom resources.

5.2 — Create the Middlewares
bash
cat > ~/lab3/msa/14-traefik-middlewares.yaml <<'EOF'
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-api-py
  namespace: multi-service-app
spec:
  stripPrefix:
    prefixes:
      - /api/py
---
apiVersion: traefik.io/v1alpha1
kind: Middleware
metadata:
  name: strip-api-node
  namespace: multi-service-app
spec:
  stripPrefix:
    prefixes:
      - /api/node
EOF
kubectl apply -f ~/lab3/msa/14-traefik-middlewares.yaml
kubectl get middlewares
kubectl describe middleware strip-api-py
Expect: two Middleware objects.
Note the apiVersion is traefik.io/v1alpha1. Older docs and blog posts use traefik.containo.us/v1alpha1, which is the legacy group name — if you copy one of those, the API server rejects it with no matches for kind. A live check beats a search result:
bash
kubectl api-resources | grep traefik
kubectl explain middleware.spec.stripPrefix
kubectl explain works on a CRD exactly as it works on a Pod, because the CRD shipped an OpenAPI schema. That's what makes a custom resource a first-class citizen rather than a blob.
5.3 — Write the Ingress
bash
cat > ~/lab3/msa/15-ingress.yaml <<'EOF'
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: msa-ingress
  namespace: multi-service-app
  annotations:
    # Format: <middleware-namespace>-<middleware-name>@kubernetescrd
    traefik.ingress.kubernetes.io/router.middlewares: >-
      multi-service-app-strip-api-py@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /api/py
            pathType: Prefix
            backend:
              service:
                name: python-api
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: msa-ingress-node
  namespace: multi-service-app
  annotations:
    traefik.ingress.kubernetes.io/router.middlewares: >-
      multi-service-app-strip-api-node@kubernetescrd
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /api/node
            pathType: Prefix
            backend:
              service:
                name: node-api
                port:
                  number: 80
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: msa-ingress-frontend
  namespace: multi-service-app
spec:
  ingressClassName: traefik
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: react-frontend
                port:
                  number: 80
EOF
kubectl apply -f ~/lab3/msa/15-ingress.yaml
kubectl get ingress
kubectl describe ingress msa-ingress
	Why three Ingress objects instead of one
	Because middleware annotations apply to the whole Ingress object, not to a single path. Annotations live in metadata, and metadata describes the object. One Ingress with all three paths could carry only one middleware annotation, and it would strip /api/py from every route including the frontend's.
	This is a structural limitation of the annotation model, not a Traefik quirk. Path-level configuration is impossible when your configuration lives in object metadata. Note how it fragments your routing: three objects that logically belong together, split apart by a mechanism limitation. Then look at Step 7, where a single HTTPRoute carries per-rule filters and the split disappears.
Also note the two things the API server did and did not validate. It validated pathType against an enum, port.number as an integer, ingressClassName as a string. It did not validate the annotation key, the annotation value, that multi-service-app-strip-api-py@kubernetescrd refers to anything real, or that @kubernetescrd is a syntax any controller recognises.
5.4 — Verify, one path at a time
bash
echo "== frontend"
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/
echo "== python-api health (expect the app's /health JSON)"
curl -sS http://localhost:30080/api/py/health; echo
echo "== python-api db"
curl -sS http://localhost:30080/api/py/api/db; echo
echo "== node-api health"
curl -sS http://localhost:30080/api/node/health; echo
echo "== node-api db"
curl -sS http://localhost:30080/api/node/api/db; echo
Expect: 200 from the frontend; real JSON from all four API calls.
Trace the /api/py/api/db request in your head — this is the bit worth being able to recite:
Windows browser  →  172.31.17.54:30080
                    (Docker port mapping on lab3-control-plane)
                 →  control-plane node's NodePort 30080
                    (kube-proxy DNAT)
                 →  Traefik Pod on lab3-worker2, container port 8000
                    (Traefik router matches PathPrefix /api/py)
                 →  strip-api-py middleware rewrites path to /api/db
                 →  python-api Service :80
                    (kube-proxy DNAT again)
                 →  python-api Pod :8001, handler for /api/db
                 →  postgres-db Service :5432
                 →  postgres Pod :5432
Nine hops, three DNAT translations, two DNS lookups, one path rewrite. In Lab 02 this was one nginx location block and Docker's embedded DNS. Everything on that list is something you can now inspect individually — which is precisely why 3.4's triage sub-lab is next.
5.5 — Confirm the stripping actually happened
Don't take the 200 as proof. Look at what the app received:
bash
kubectl logs -l app=python-api --tail=20
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=20 | grep -v '^time.*level=info'
Expect: python-api's access log shows GET /api/db, not GET /api/py/api/db. If it shows the full path, the middleware isn't attached — see Step 9's exercise 1, which you may have just done accidentally.
5.6 — From Windows: the actual goal
powershell
PS> Start-Process "http://172.31.17.54:30080/"
Expect: the React app loads, and both status cards go green. Open DevTools → Network and confirm the XHRs go to /api/py/... and /api/node/... on the same origin as the page, with no CORS preflight anywhere.
This is the moment kubectl port-forward retires. Compare what you're doing now to 3.1 §4.6, where you needed an SSH tunnel and a forward per Service, and got a debugging tunnel through the API server that couldn't load-balance. Now: one address, real traffic path, real load balancing, no API server involvement.
5.7 — [Deep dive] The Traefik dashboard
bash
kubectl port-forward -n traefik "$(kubectl get pod -n traefik -o name | head -1)" 9000:9000
Then http://localhost:9000/dashboard/ over an SSH tunnel. You'll see your three Ingress objects rendered as Traefik routers, each with its middleware chain and backing service. Seeing Kubernetes objects translated into a proxy's own vocabulary is genuinely clarifying: an Ingress is a description, and the controller's job is to turn it into proxy configuration.
Note the dashboard is not exposed by default in the chart values. That's correct — it's an unauthenticated admin interface.

Step 6 — Gateway API: the same routing, typed [PLAT] + [DEV]
6.1 — Remove the Ingress objects first
bash
kubectl delete -f ~/lab3/msa/15-ingress.yaml
kubectl get ingress
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/    # back to 404
Why delete rather than leave both running: Traefik would build routers from both providers on the same entrypoint, with overlapping path rules. Which one wins depends on internal priority calculations, and you'd be debugging a routing conflict instead of learning Gateway API. Keep the file — Step 8 and Sub-lab 3.10 both use it.
6.2 — Inspect what already exists
bash
kubectl get gatewayclass traefik -o yaml
kubectl get gateway -n traefik -o yaml
kubectl describe gateway -n traefik
Expect: the Gateway (created by the chart) with listeners, an assigned address, PROGRAMMED: True, and attachedRoutes: 0.
The three-object model, and why it's split this way:
Object	Answers	Owner	Analogue
GatewayClass	"what implementation?"	the vendor / cluster installer	StorageClass, IngressClass
Gateway	"what ports, protocols, hostnames does the cluster listen on?"	[PLAT] — the platform team	nginx's listen directives
HTTPRoute	"where does this path go?"	[DEV] — the app team	nginx's location blocks
Why it matters — this is the sub-lab's central insight. In the Ingress model, listener configuration and routing rules are jammed into the same object, so a developer who needs a new path either edits a shared object or gets a platform engineer to do it. Gateway API splits them along the exact line your organisation already splits along. The Gateway lives in the traefik namespace with platform RBAC on it; HTTPRoute objects live in app namespaces with app-team RBAC.
That's not a happy accident. Ingress's failure to separate these concerns is a stated motivation for Gateway API's design. The API encodes an org chart — which is a genuinely unusual thing for an API to do, and worth noticing.
6.3 — The namespace boundary (and the reason from: All is in your values)
attachedRoutes: 0 is not just because you haven't written routes. By default, a Gateway only accepts routes from its own namespace. Your Gateway is in traefik; your routes will be in multi-service-app.
bash
kubectl get gateway -n traefik -o jsonpath='{.items[0].spec.listeners[0].allowedRoutes}' | python3 -m json.tool
Expect: {"namespaces": {"from": "All"}} — because you set namespacePolicy.from: All in §4.4.
Three options exist, and the difference is the security model:
from	Meaning
Same	default. Only routes in the Gateway's own namespace. Nothing gets in by accident.
Selector	Only namespaces matching a label selector. The production answer.
All	Any namespace. Convenient, and what you're using.
Why the default is Same: an open Gateway means any team who can create an HTTPRoute in any namespace can publish routes on the cluster's public entry point — including hijacking a path that belongs to someone else. Gateway API makes this explicit and opt-in. Ingress had no equivalent control at all, which is one of its real security weaknesses.
	If Step 6.5 returns 404 and everything else looks right, this is the first thing to check. The symptom is a route whose status says it wasn't accepted by the Gateway.
6.4 — Write the HTTPRoute
bash
cat > ~/lab3/msa/16-httproute.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: msa-route
  namespace: multi-service-app
spec:
  parentRefs:
    - name: traefik-gateway        # <-- VERIFY with: kubectl get gateway -n traefik
      namespace: traefik
      kind: Gateway
  rules:
    # ---- /api/py -> python-api, prefix stripped ----
    - matches:
        - path:
            type: PathPrefix
            value: /api/py
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: python-api
          port: 80
    # ---- /api/node -> node-api, prefix stripped ----
    - matches:
        - path:
            type: PathPrefix
            value: /api/node
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: node-api
          port: 80
    # ---- everything else -> react-frontend, path untouched ----
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: react-frontend
          port: 80
EOF
Verify the Gateway's real name before applying:
bash
kubectl get gateway -n traefik -o name
# if it isn't 'traefik-gateway', fix parentRefs.name
kubectl apply -f ~/lab3/msa/16-httproute.yaml
Read this manifest against Step 5.3's three Ingress objects and notice five things:
	1. One object, three rules. The fragmentation caused by object-level annotations is gone.
	2. filters are per-rule. The rewrite applies to the rule it's written in. No CRD, no annotation, no @kubernetescrd string.
	3. The rewrite is typed. ReplacePrefixMatch is an enum in the schema. Misspell it and the API server rejects it immediately — as opposed to an annotation typo, which is accepted and silently ignored.
	4. parentRefs is an explicit, cross-namespace reference. The route names the Gateway it wants to attach to, and the Gateway independently decides whether to accept it. Two-sided consent, in the API.
	5. backendRefs is a list. That plural is Step 7's canary, and it's the field Ingress simply doesn't have.
6.5 — Verify — including route status, which is new
bash
kubectl get httproute
kubectl describe httproute msa-route
Expect — and this is the part Ingress never gave you — a status block with two conditions per parent:
Status:
  Parents:
    Conditions:
      Type:    Accepted     Status: True   Reason: Accepted
      Type:    ResolvedRefs Status: True   Reason: ResolvedRefs
Accepted = the Gateway agreed to attach this route (this is where a namespace-policy rejection shows up). ResolvedRefs = every backendRefs target actually exists. A typo'd Service name turns this False with a clear reason, on the route object itself.
Compare against your kubectl describe ingress output in Step 5.3, which told you essentially nothing about whether anything worked. Machine-readable status on routing objects is one of Gateway API's biggest practical wins — it means CI can assert that a route is live rather than curling a URL and hoping.
bash
kubectl get gateway -n traefik -o jsonpath='{.items[0].status.listeners[0].attachedRoutes}'; echo   # 1
Now the traffic:
bash
curl -sS -o /dev/null -w 'frontend  HTTP %{http_code}\n' http://localhost:30080/
curl -sS http://localhost:30080/api/py/health;      echo
curl -sS http://localhost:30080/api/py/api/db;      echo
curl -sS http://localhost:30080/api/node/health;    echo
curl -sS http://localhost:30080/api/node/api/db;    echo
kubectl logs -l app=python-api --tail=10   # confirm it received /api/db, not /api/py/api/db
Expect: byte-for-byte identical results to Step 5.4. Same proxy, same Pods, same everything — only the API changed. That's exactly the comparison this sub-lab was built to isolate.
From Windows: reload http://172.31.17.54:30080/. Both cards green again.
6.6 — The comparison, filled in from experience
You've now done the same job twice. Fill this in from what you actually observed, not from documentation:
Concern	Ingress (as you experienced it)	Gateway API (as you experienced it)
Objects needed for 3 routes	3 Ingresses + 2 Middleware CRDs = 5	1 HTTPRoute = 1
Path rewriting	vendor CRD + annotation string with @provider syntax	typed URLRewrite filter, in-spec
Per-path config	impossible — annotations are object-scoped	native, filters sit inside rules
Typo in rewrite config	silently accepted, silently ignored	rejected by the API server
Did it work?	curl it and hope	Accepted / ResolvedRefs conditions
Listener vs route ownership	same object, one owner	Gateway [PLAT] / HTTPRoute [DEV]
Cross-namespace	not expressible	parentRefs + allowedRoutes, two-sided
Traffic splitting	vendor annotation, if at all	backendRefs weights, first-class
Portable to another controller	no — rewrite every annotation	yes, that's the design goal
Say the retirement rationale in one sentence. Something like: ingress-nginx was retired as a project, and Ingress as an API is being superseded because everything beyond basic path routing had to be expressed as unvalidated, vendor-specific annotations — so Ingress configuration was never portable and never verifiable.
6.7 — [Deep dive] Match on more than a path
Ingress can match a host and a path. That's the entire vocabulary. Gateway API matches on headers, methods, and query parameters:
bash
kubectl patch httproute msa-route --type=json -p '[
  {"op":"add","path":"/spec/rules/0/matches/0/headers","value":[
    {"type":"Exact","name":"X-Lab-Debug","value":"yes"}
  ]}
]'
curl -sS -o /dev/null -w 'no header:   HTTP %{http_code}\n' http://localhost:30080/api/py/health
curl -sS -o /dev/null -w 'with header: HTTP %{http_code}\n' -H 'X-Lab-Debug: yes' http://localhost:30080/api/py/health
Expect: without the header the request falls through to the / rule (the frontend) and gets a 200 for the wrong content or a 404; with it, the API responds.
Revert:
bash
kubectl apply -f ~/lab3/msa/16-httproute.yaml
Header- and method-based matching is what makes feature flags, A/B tests, and internal-only debug endpoints expressible in the routing layer. In Lab 02 you'd have written an if block in nginx config. Here it's a schema field.

Step 7 — The canary: weighted traffic splitting [PLAT]
This is a five-line change that Ingress could not portably express at all, and it's a direct preview of 3.5's rollout work.
7.1 — A second backend to split toward
Same image, different labels, so you can tell the responses apart via the Downward API values from Step 1.3.
bash
sed -e 's/name: node-api/name: node-api-canary/' \
    -e 's/app: node-api/app: node-api-canary/' \
    ~/lab3/msa/10-node-api-deployment.yaml > ~/lab3/msa/17-node-api-canary-deployment.yaml
sed -e 's/name: node-api/name: node-api-canary/' \
    -e 's/app: node-api/app: node-api-canary/' \
    ~/lab3/msa/11-node-api-service.yaml > ~/lab3/msa/18-node-api-canary-service.yaml
# the canary reuses the stable ConfigMap
sed -i 's/name: node-api-canary-config/name: node-api-config/' \
    ~/lab3/msa/17-node-api-canary-deployment.yaml
grep -nE 'name:|app:' ~/lab3/msa/17-node-api-canary-deployment.yaml | head -20
kubectl apply -f ~/lab3/msa/17-node-api-canary-deployment.yaml
kubectl apply -f ~/lab3/msa/18-node-api-canary-service.yaml
kubectl rollout status deployment/node-api-canary --timeout=120s
kubectl get pods -l 'app in (node-api,node-api-canary)' -o wide
Check the sed output before applying — blind sed on YAML is exactly how you get a Deployment whose selector doesn't match its template, which the API server will reject (3.1 §5.2, point 2).
7.2 — Split 90/10
bash
cat > ~/lab3/msa/19-httproute-canary.yaml <<'EOF'
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: msa-route
  namespace: multi-service-app
spec:
  parentRefs:
    - name: traefik-gateway
      namespace: traefik
      kind: Gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /api/py
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: python-api
          port: 80
    # 90/10 split across two backends
    - matches:
        - path:
            type: PathPrefix
            value: /api/node
      filters:
        - type: URLRewrite
          urlRewrite:
            path:
              type: ReplacePrefixMatch
              replacePrefixMatch: /
      backendRefs:
        - name: node-api
          port: 80
          weight: 90
        - name: node-api-canary
          port: 80
          weight: 10
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: react-frontend
          port: 80
EOF
kubectl apply -f ~/lab3/msa/19-httproute-canary.yaml
kubectl describe httproute msa-route | sed -n '/Status:/,$p'
7.3 — Observe the split
bash
for i in $(seq 1 60); do
  curl -sS -m 3 http://localhost:30080/api/node/api/info \
    | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('pod') or d.get('host') or d.get('hostname'))" 2>/dev/null
done | sort | uniq -c | sort -rn
Expect roughly:
  54 node-api-7d9c8b5f4-x2k9p
   6 node-api-canary-6b8f7c9d2-m4n8q
Not exact — weights are proportional, not a strict rotation, and 60 requests is a small sample. Roughly 9:1 is a pass.
Why it matters: you just did a canary deployment with a declarative weight change and no proxy config, no annotation, and no controller-specific feature. Change the weights to 50/50, apply, and traffic shifts within a second. That's the primitive underneath every progressive-delivery tool — Argo Rollouts and Flagger are essentially automation that watches metrics and edits these two numbers for you.
Also notice what's missing: there is no "canary" object, no special mode, no plugin. Two backends and two integers.
7.4 — Clean up the canary
bash
kubectl apply -f ~/lab3/msa/16-httproute.yaml         # back to single backend
kubectl delete -f ~/lab3/msa/18-node-api-canary-service.yaml
kubectl delete -f ~/lab3/msa/17-node-api-canary-deployment.yaml
kubectl get pods
Keep the files. 3.5 revisits this properly alongside rolling updates.

Step 8 — Break it on purpose
Four exercises. Each one takes five minutes and each one is a failure you will meet for real. Write the broken manifests into ~/lab3/broken/ so 3.4 can reuse them.
8.1 — The annotation typo (the headline lesson)
bash
kubectl apply -f ~/lab3/msa/15-ingress.yaml
kubectl delete httproute msa-route
# Typo the annotation KEY — 'middleware' instead of 'middlewares'
kubectl annotate ingress msa-ingress --overwrite \
  'traefik.ingress.kubernetes.io/router.middleware=multi-service-app-strip-api-py@kubernetescrd'
kubectl annotate ingress msa-ingress 'traefik.ingress.kubernetes.io/router.middlewares-'
kubectl describe ingress msa-ingress | sed -n '/Annotations:/,/Rules:/p'
kubectl get events --sort-by=.lastTimestamp | tail -5
curl -sS http://localhost:30080/api/py/health; echo
kubectl logs -l app=python-api --tail=5
Expect: the API server accepted it happily. Zero warnings, zero events. And the app now receives GET /api/py/health, which it doesn't serve — so a 404 from your application, which looks nothing like a routing problem.
Why it matters: you have a silent misconfiguration presenting as an application bug. Nothing in Kubernetes will ever tell you the annotation key is wrong, because to the API server it is just a string in a map. Someone will spend an afternoon reading FastAPI routing code.
Now the contrast:
bash
kubectl patch ingress msa-ingress --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/http/paths/0/pathType","value":"Prefixx"}]'
Expect: immediate rejection — Unsupported value: "Prefixx", with the valid values listed.
Two typos, one character each, in the same object. One is caught before it exists; the other ships to production silently. The difference is that pathType is in the schema and the annotation is not. That is the entire argument for Gateway API in one experiment.
Restore:
bash
kubectl delete -f ~/lab3/msa/15-ingress.yaml
kubectl apply -f ~/lab3/msa/15-ingress.yaml
curl -sS http://localhost:30080/api/py/health; echo
8.2 — Gateway API's version of the same mistake
bash
kubectl delete -f ~/lab3/msa/15-ingress.yaml
kubectl apply -f ~/lab3/msa/16-httproute.yaml
kubectl patch httproute msa-route --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/filters/0/urlRewrite/path/type","value":"ReplacePrefixMatchh"}]'
Expect: rejected. ReplacePrefixMatchh isn't in the enum.
Then the failure mode Gateway API does let through:
bash
kubectl patch httproute msa-route --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/name","value":"python-api-typo"}]'
kubectl describe httproute msa-route | sed -n '/Status:/,$p'
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/api/py/health
Expect: the object is accepted (the API server can't know whether a Service exists yet — it might be created later), the request fails, and ResolvedRefs is False with a reason naming the missing backend.
This is the important half. Gateway API doesn't prevent every mistake — it makes them reportable. The error is on the object, machine-readable, ready for kubectl wait --for=condition=ResolvedRefs in a pipeline. Ingress gave you nothing to assert on.
bash
kubectl apply -f ~/lab3/msa/16-httproute.yaml   # restore
8.3 — The namespace policy
bash
kubectl patch gateway -n traefik traefik-gateway --type=json \
  -p '[{"op":"replace","path":"/spec/listeners/0/allowedRoutes/namespaces/from","value":"Same"}]'
sleep 3
kubectl describe httproute msa-route | sed -n '/Status:/,$p'
kubectl get gateway -n traefik -o jsonpath='{.items[0].status.listeners[0].attachedRoutes}'; echo
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/
Expect: Accepted: False, reason NotAllowedByListeners. attachedRoutes: 0. A 404 from Traefik.
Why it matters: app-team route, platform-team Gateway, and the platform side said no. The route is perfectly valid and does nothing. In a real org this is a ticket, not a bug — and Gateway API told you exactly which side of the boundary the problem is on, which Ingress could never do.
bash
kubectl patch gateway -n traefik traefik-gateway --type=json \
  -p '[{"op":"replace","path":"/spec/listeners/0/allowedRoutes/namespaces/from","value":"All"}]'
sleep 3
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/
8.4 — The wrong-port failure (preview of 3.4 #7)
bash
kubectl patch httproute msa-route --type=json \
  -p '[{"op":"replace","path":"/spec/rules/0/backendRefs/0/port","value":8080}]'
kubectl describe httproute msa-route | sed -n '/Status:/,$p'
curl -sS -o /dev/null -w 'HTTP %{http_code}\n' http://localhost:30080/api/py/health
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=20
Expect: ResolvedRefs may well be True — the Service exists, and port 8080 is a plausible-looking number. But nothing is listening on it, so the request 502s.
Why it matters: this is the distinction 3.4 exercises #6 and #7 are built around. A missing backend and a wrong port on a real backend look similar from a browser and are completely different problems. Status conditions catch the first; only the proxy's logs catch the second. Knowing which tool sees which failure is the skill.
bash
kubectl apply -f ~/lab3/msa/16-httproute.yaml
curl -sS http://localhost:30080/api/py/health; echo

Step 9 — Wrap up and decide what stays
9.1 — Choose your entry point
You now have two working configurations. Leave Gateway API applied and keep the Ingress files on disk:
bash
kubectl get ingress          # should be empty
kubectl get httproute        # msa-route, Accepted, ResolvedRefs
ls -l ~/lab3/msa/15-ingress.yaml ~/lab3/msa/16-httproute.yaml
Sub-labs 3.5 and 3.7 build on the Gateway API version. 3.10 templates both with Kustomize, which is a nice test of overlays.
9.2 — Final verification
bash
kubectl get all
kubectl get httproute,middlewares,cm,secret
kubectl get gateway,gatewayclass -A
helm list -A
for p in / /api/py/health /api/py/api/db /api/node/health /api/node/api/db; do
  printf '%-24s ' "$p"
  curl -sS -o /dev/null -w 'HTTP %{http_code}\n' -m 5 "http://localhost:30080$p"
done
From Windows, one last time: http://172.31.17.54:30080/ — both cards green.
9.3 — Save your state
bash
cd ~/lab3
kubectl get -o yaml \
  deploy,svc,cm,httproute,middlewares > ~/lab3/msa/_snapshot-3.3.yaml
ls -l ~/lab3/msa/
free -h
docker system df
Not a backup — a reference for when 3.10 asks "what should kubectl apply -k reproduce?"
9.4 — What to keep, what not to do
Keep: the lab3 cluster, everything in ~/lab3/, the Traefik Helm release, the Gateway API CRDs, the multi-service-app namespace and your context default.
Do not: helm uninstall traefik (3.5 through 3.10 all need it), delete the Gateway API CRDs (deleting a CRD deletes every object of that type, cluster-wide, immediately), or kind delete cluster.
Genuinely safe to clean up:
bash
kubectl get pods | grep -E 'curl-test|tmp-shell|pg-probe'   # should be empty; --rm handles it
rm -rf ~/lab3/traefik/rendered.yaml                          # regenerate any time

Verification checklist
Workloads [DEV]
	• node-api and react-frontend images built and loaded onto all three nodes.
	• The two-image-stores surprise from 3.2 §1.3 observed directly.
	• node-api: init container Completed with exit 0 before the main container started.
	• node-api env shows ConfigMap + Secret + Downward API values in one flat namespace.
	• Frontend bundle verified to contain /api/py and no hardcoded host or port.
	• The react-frontend manifest is visibly simpler, and you can explain what that says about the app.
	• All four Deployments 1/1, RESTARTS 0, with populated EndpointSlices.
	• Full internal test passed before any routing was added.
Entry point [PLAT]
	• ufw checked; the Docker-bypasses-ufw behaviour tested and understood.
	• helm show values read before installing.
	• helm template rendered and the Service type/nodePort confirmed before installing.
	• Traefik on NodePort 30080/30443, matching 3.1's extraPortMappings, no rebuild.
	• Can explain how traffic reaches a Traefik Pod on a worker via a control-plane NodePort.
	• Can explain why NodePort needs no node pinning and hostPort does.
	• Gateway API CRDs installed; kubectl api-resources demonstrably longer than before.
Ingress [DEV] + [PLAT]
	• Traefik Middleware CRDs created for prefix stripping.
	• Understood why three Ingress objects were needed instead of one.
	• All five paths serve correctly through port 30080.
	• Confirmed stripping from the app's own logs, not from the HTTP status code.
	• Both status cards green from Windows; no CORS in DevTools.
	• kubectl port-forward retired.
Gateway API [PLAT] + [DEV]
	• GatewayClass / Gateway / HTTPRoute roles articulated, with owners.
	• Understood the allowedRoutes.namespaces.from default and why it's Same.
	• One HTTPRoute replaced 5 objects, with per-rule URLRewrite filters.
	• Accepted and ResolvedRefs conditions read and understood.
	• Byte-identical results to the Ingress pass — same proxy, only the API changed.
	• Comparison table filled in from experience.
	• Retirement rationale stated in one sentence mentioning annotations.
	• (Deep dive) Header-based matching tried.
Canary [PLAT]
	• 90/10 split observed across two backends via Pod names.
	• Can explain why this was not portably expressible in Ingress.
Break-it
	• Annotation-key typo: silently accepted, no events, presents as an app 404.
	• pathType typo: rejected instantly. Both understood as the same argument.
	• Gateway API enum typo rejected; bad backend name reported via ResolvedRefs: False.
	• Namespace policy set to Same: route valid, Accepted: False, traffic dead.
	• Wrong port: ResolvedRefs: True but 502 — only visible in proxy logs.

Troubleshooting
curl http://localhost:30080/ → Connection refused
The port chain, not routing.
bash
docker ps --format 'table {{.Names}}\t{{.Ports}}' | grep lab3-control-plane   # is 30080 mapped?
kubectl get svc -n traefik                                                     # is nodePort 30080?
kubectl get pods -n traefik -o wide                                            # is Traefik Running?
sudo ss -tulpn | grep 30080
If docker ps doesn't show the mapping, your extraPortMappings didn't apply — and that is the one thing here that does need a cluster recreate from ~/lab3/kind-lab3.yaml.
Everything returns 404 from Traefik
Traefik is fine, nothing matches.
bash
kubectl get ingress,httproute
kubectl describe httproute msa-route | sed -n '/Status:/,$p'    # Accepted? ResolvedRefs?
kubectl get gateway -n traefik -o jsonpath='{.items[0].status.listeners[0].attachedRoutes}'; echo
kubectl logs -n traefik -l app.kubernetes.io/name=traefik --tail=50
attachedRoutes: 0 with a valid route → namespace policy (§6.3).
API returns 404 but the frontend works
The prefix isn't being stripped, so the app gets a path it doesn't serve.
bash
kubectl logs -l app=python-api --tail=10        # is it receiving /api/py/api/db?
kubectl describe ingress msa-ingress | sed -n '/Annotations:/,/Rules:/p'
kubectl get middlewares
Check the annotation key spelling and the <namespace>-<name>@kubernetescrd format.
502 Bad Gateway
Route matched, backend unreachable.
bash
kubectl get endpointslices                     # empty = selector/readiness problem
kubectl get svc python-api -o yaml | grep -A5 ports
kubectl get pods -o wide
Frontend loads, status cards red
Routing is fine; the browser is calling the wrong URL. Open DevTools → Network, look at the failing request's URL. If it has an IP or a port in it, the bundle was built with absolute URLs — go back to §2.1 and rebuild. No amount of routing configuration fixes this, because the URL is compiled into the JavaScript.
Reachable from Ubuntu, not from Windows
bash
sudo ufw status verbose
ip a | grep 172.31
powershell
PS> Test-NetConnection 172.31.17.54 -Port 30080
no matches for kind "Middleware" / "HTTPRoute"
CRDs missing or wrong API group.
bash
kubectl api-resources | grep -iE 'traefik|gateway'
kubectl get crd | grep -E 'traefik|gateway'
Use traefik.io/v1alpha1, not the legacy traefik.containo.us/v1alpha1.
Helm values seem to be ignored
bash
helm get values traefik -n traefik              # what Helm thinks you asked for
helm get manifest traefik -n traefik | awk '/^kind: Service$/,/^---/'   # what it produced
grep -n -A10 '^service:' ~/lab3/traefik/values-reference.yaml           # what the chart accepts
Almost always a renamed key in a newer chart version. Trust values-reference.yaml.

[PARKED] — for a future pass
Real and useful, deliberately out of scope today:
	• TLS termination + cert-manager. The websecure listener and NodePort 30443 exist and are unused. Needs a real DNS name to be worth doing, so it belongs with the EKS lab.
	• ReferenceGrant — the object that lets an HTTPRoute reference a Service in another namespace. You met the Gateway-side namespace boundary in §6.3; this is the backend-side equivalent.
	• GRPCRoute, request mirroring (shadow traffic to a new version with no user impact), typed retry and timeout policies.
	• cloud-provider-kind — makes type: LoadBalancer actually work on KinD, so your manifests match what EKS will want.
	• Traefik's IngressRoute CRD — its own richer routing object, predating Gateway API. Worth recognising in the wild; don't build on it now, since Gateway API is the portable answer.
	• Migrating ingress-nginx annotations to Gateway API. A real 2026 job task. Traefik's nginx-annotation compatibility layer is the interesting shortcut.
	• Rate limiting, basic auth, and forward auth middleware — the layer between routing and a service mesh.

Sequencing note
Do Sub-lab 3.4 (failure triage) next, before 3.5. You now have nine hops between a browser and a database row, and every one of them can fail in a way that looks like "the site is down." 3.4 builds the procedure. 3.5 then breaks things on purpose under load, which goes much better when you already have one.
