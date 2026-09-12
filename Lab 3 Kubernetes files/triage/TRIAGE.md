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
