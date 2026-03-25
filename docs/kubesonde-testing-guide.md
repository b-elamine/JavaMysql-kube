# Kubesonde Testing Guide — Spring PetClinic on Minikube

> **What is kubesonde?**
> A Kubernetes operator that probes your cluster's **actual** network connectivity — from inside running pods — and compares results against what you **expect**. It surfaces NetworkPolicy misconfigurations that are invisible to `kubectl` alone.
>
> Source: [`github.com/kubesonde/kubesonde`](https://github.com/kubesonde/kubesonde)

---

## Table of Contents

1. [What You Will See](#1-what-you-will-see)
2. [Cluster Map](#2-cluster-map)
3. [Phase 1 — Cluster Setup](#3-phase-1--cluster-setup)
4. [Phase 2 — Deploy PetClinic](#4-phase-2--deploy-petclinic)
5. [Phase 3 — Add Scenario Workloads](#5-phase-3--add-scenario-workloads)
6. [Phase 4 — Deploy Kubesonde](#6-phase-4--deploy-kubesonde)
7. [Phase 5 — Trigger the Probes](#7-phase-5--trigger-the-probes)
8. [Phase 6 — Fetch and Read Results](#8-phase-6--fetch-and-read-results)
9. [Phase 7 — Understanding the Findings](#9-phase-7--understanding-the-findings)
10. [Phase 8 — Experiment: Fix the MySQL Egress Gap](#10-phase-8--experiment-fix-the-mysql-egress-gap)
11. [Phase 9 — Visualize in the React UI](#11-phase-9--visualize-in-the-react-ui)
12. [Troubleshooting](#12-troubleshooting)
13. [Quick Reference](#13-quick-reference)

---

## 1. What You Will See

Running kubesonde against this project surfaces four concrete findings:

| # | Finding | Severity | Root Cause |
|---|---------|----------|------------|
| 1 | MySQL can reach the internet (egress unrestricted) | High | `mysql-network-policy` covers Ingress only — Egress is open |
| 2 | Any pod in `pet-clinic-app` can connect to `java-app:8080` | Medium | No ingress NetworkPolicy on java-app |
| 3 | `db-admin` (same namespace as mysql) is blocked from port 3306 | — | Policy works as designed |
| 4 | After applying the fix, mysql → internet transitions to Deny | — | Confirmed by re-probe |

Finding #1 is the most important. A NetworkPolicy that only declares `policyTypes: [Ingress]` leaves egress **completely unrestricted**. A compromised database pod could exfiltrate data over HTTP/HTTPS to an attacker-controlled server, and Kubernetes would not block it.

---

## 2. Cluster Map

This is the full picture of what gets deployed and what kubesonde will probe:

```
┌─────────────────────────────────────────────────────────────────┐
│ Namespace: pet-clinic-app                                       │
│                                                                  │
│   pod: java-app            Spring Boot 8080                     │
│   pod: monitoring-probe    busybox (simulates a sidecar agent)  │
│                                                                  │
│   NetworkPolicy: NONE on java-app ingress  ◄── Finding #2       │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Namespace: pet-clinic-db                                        │
│                                                                  │
│   pod: mysql-0             MySQL 3306 (StatefulSet)             │
│   pod: db-admin            busybox (simulates phpMyAdmin)       │
│                                                                  │
│   NetworkPolicy: mysql-network-policy                           │
│     Ingress to mysql:  allowed from namespace name=pet-clinic-app│
│     Egress from mysql: UNRESTRICTED  ◄── Finding #1             │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│ Namespace: kubesonde-system                                     │
│                                                                  │
│   pod: kubesonde-controller-manager                             │
│     → injects ephemeral "debugger" containers into every pod    │
│     → runs nmap/nslookup from inside each pod                   │
│     → serves results on REST API :2709                          │
└─────────────────────────────────────────────────────────────────┘
```

---

## 3. Phase 1 — Cluster Setup

### Why Calico is mandatory

The default minikube CNI (`kindnet`) does **not** enforce `NetworkPolicy` resources — the rules exist in the API server but are silently ignored at the network level. Calico is a full CNI plugin that actually programs the iptables/eBPF rules that implement policies.

Without Calico, every kubesonde probe returns `Allow` regardless of what policies you have, making results meaningless.

### 3.1 Delete any existing cluster

```bash
minikube delete
```

### 3.2 Start a 3-node cluster with Calico

The PetClinic project pins MySQL to node `minikube-m02` via node affinity, so exactly 3 nodes are required.

```bash
minikube start \
  --nodes=3 \
  --cni=calico \
  --driver=docker \
  --kubernetes-version=v1.28.0 \
  --memory=3072 \
  --cpus=2
```

> **Resource note:** This allocates ~9 GB RAM and 6 vCPUs total across 3 nodes. If your machine is constrained, use `--memory=2048`.

### 3.3 Wait for Calico to be ready

Calico's node pods start in `kube-system`. Allow ~2 minutes after `minikube start` completes:

```bash
kubectl wait --for=condition=Ready pods \
  -l k8s-app=calico-node \
  -n kube-system \
  --timeout=3m
```

### 3.4 Enable required addons

```bash
minikube addons enable ingress
minikube addons enable metrics-server
```

### 3.5 Taint the MySQL node

This dedicates `minikube-m02` to MySQL and rejects all other workloads from scheduling there:

```bash
kubectl taint nodes minikube-m02 dedicated=db:NoSchedule
```

### 3.6 Verify all nodes are Ready

```bash
kubectl get nodes
```

Expected output:

```
NAME           STATUS   ROLES           AGE   VERSION
minikube       Ready    control-plane   Xm    v1.28.0
minikube-m02   Ready    <none>          Xm    v1.28.0
minikube-m03   Ready    <none>          Xm    v1.28.0
```

---

## 4. Phase 2 — Deploy PetClinic

All commands run from the project root:

```bash
cd /path/to/javaAppK8s/spring-petclinic
```

### 4.1 Create namespaces with labels

The labels are **critical**. The MySQL NetworkPolicy uses a `namespaceSelector` that matches `name=pet-clinic-app`. Without this label, `java-app` cannot reach MySQL and the application will fail to start.

```bash
kubectl create namespace pet-clinic-app
kubectl create namespace pet-clinic-db

kubectl label namespace pet-clinic-app name=pet-clinic-app
kubectl label namespace pet-clinic-db  name=pet-clinic-db
```

### 4.2 Apply secrets (database credentials)

```bash
kubectl apply -f kube-configs/secret.yml
kubectl apply -f kube-configs/secret-db.yml
```

### 4.3 Deploy MySQL first

Java-app depends on MySQL being ready. Deploy MySQL and wait for it before moving on.

```bash
kubectl apply -f kube-configs/mysql/resource-management.yml
kubectl apply -f kube-configs/mysql/configmap.yml

# The NetworkPolicy — this is the one kubesonde will validate
kubectl apply -f kube-configs/mysql/network-policy.yml

# StatefulSet + Service + PVC
kubectl apply -f kube-configs/mysql/mysql.yml
```

Wait for MySQL to initialize (it runs an `init.sql` on first boot — takes ~2 min):

```bash
kubectl rollout status statefulset/mysql -n pet-clinic-db --timeout=5m
```

### 4.4 Deploy java-app

```bash
kubectl apply -f kube-configs/java-app/resource-management.yml
kubectl apply -f kube-configs/java-app/configmap.yml
kubectl apply -f kube-configs/java-app/java.yml
kubectl apply -f kube-configs/java-app/hpa.yml
kubectl apply -f kube-configs/java-app/pdb.yml
kubectl apply -f kube-configs/java-app/ingress.yml
```

java-app has a startup probe with up to 10 minutes of retries (waiting for MySQL). Watch the rollout:

```bash
kubectl rollout status deployment/java-app -n pet-clinic-app --timeout=12m
```

### 4.5 Verify

Both pods should be `1/1 Running`:

```bash
kubectl get pods -n pet-clinic-app
kubectl get pods -n pet-clinic-db
```

---

## 5. Phase 3 — Add Scenario Workloads

These two extra pods are **not** part of the PetClinic application. They are added to create meaningful security scenarios for kubesonde to analyze.

| Pod | Namespace | Purpose |
|-----|-----------|---------|
| `monitoring-probe` | `pet-clinic-app` | Simulates a sidecar/monitoring agent in the app namespace |
| `db-admin` | `pet-clinic-db` | Simulates a database admin tool (e.g., phpMyAdmin) |

```bash
kubectl apply -f kube-configs/kubesonde-scenario/extra-pods.yaml
```

Verify:

```bash
kubectl get pods -n pet-clinic-app
# java-app-XXXXX   1/1   Running
# monitoring-probe 1/1   Running

kubectl get pods -n pet-clinic-db
# mysql-0   1/1   Running
# db-admin  1/1   Running
```

---

## 6. Phase 4 — Deploy Kubesonde

### 6.1 Apply the kubesonde manifest

This installs three things: the CRD definition, the RBAC (cluster-admin level — kubesonde must inject ephemeral containers into any pod in any namespace), and the controller Deployment.

```bash
kubectl apply -f /path/to/kubesonde/kubesonde.yaml
```

### 6.2 Wait for the controller

```bash
kubectl rollout status deployment/kubesonde-controller-manager \
  -n kubesonde-system \
  --timeout=3m
```

### 6.3 Verify

```bash
kubectl get pods -n kubesonde-system
# kubesonde-controller-manager-XXXXX   1/1   Running
```

---

## 7. Phase 5 — Trigger the Probes

### 7.1 Create a Kubesonde CR per namespace

Each `Kubesonde` custom resource targets one namespace. Kubesonde discovers all pods in that namespace and probes every pod-to-pod, pod-to-service, and pod-to-internet combination.

```bash
# Probe pet-clinic-app
kubectl apply -f kube-configs/kubesonde-scenario/kubesonde-cr-app.yaml

# Probe pet-clinic-db
kubectl apply -f kube-configs/kubesonde-scenario/kubesonde-cr-db.yaml
```

**What the CR spec controls:**

```yaml
spec:
  namespace: pet-clinic-app   # which namespace to watch
  probe: all                  # probe every discovered path
  include:                    # mark specific paths as expected Allow
    - fromPodSelector: "java-app"
      port: "443"
      protocol: TCP
      expected: Allow
```

- `probe: all` — kubesonde probes every path it finds. The **default expected outcome is `Deny`**. In a well-locked-down cluster, all paths should be denied unless explicitly allowed.
- `include` — overrides specific probes with `expected: Allow`. Use this for traffic you intentionally permit (e.g., the app reaching the internet on HTTPS). Everything not in `include` remains `expected: Deny`.
- Any probe that resolves to `Allow` when `expected: Deny` is a **finding**.

### 7.2 Watch the debugger containers being injected

This is the most visible sign kubesonde is working. Each pod gains an extra container:

```bash
kubectl get pods -n pet-clinic-app -w
# java-app-XXXXX   1/1 → 2/2  (debugger container injected)
# monitoring-probe  1/1 → 2/2
```

Inspect the injected container directly:

```bash
kubectl describe pod java-app-XXXXX -n pet-clinic-app \
  | grep -A 10 "Ephemeral Containers"
```

### 7.3 Follow probe execution in the controller logs

```bash
kubectl logs -n kubesonde-system \
  deployment/kubesonde-controller-manager \
  --follow
```

Lines to look for:

| Log line | Meaning |
|----------|---------|
| `Running command: nmap ...` | A probe is executing inside a pod |
| `Probe result: Allow` | That path is reachable |
| `Probe result: Deny` | That path is blocked |
| `Recursive probing triggered` | The 20-second re-probe heartbeat started |

---

## 8. Phase 6 — Fetch and Read Results

### 8.1 Port-forward to the REST API

```bash
kubectl port-forward -n kubesonde-system \
  deployment/kubesonde-controller-manager \
  2709:2709 &
```

### 8.2 Fetch results

```bash
curl -s localhost:2709/probes | jq '.' > /tmp/results.json
```

### 8.3 Queries

**The findings — paths that are open when they should be closed:**

```bash
curl -s localhost:2709/probes | jq '
  .items[]
  | select(.expectedAction == "Deny" and .resultingAction == "Allow")
  | {
      from:     .source.name,
      to:       .destination.name,
      dest_ip:  .destination.IPAddress,
      port:     .port,
      protocol: .protocol
    }
'
```

**Which pods can reach the internet:**

```bash
curl -s localhost:2709/probes | jq '
  .items[]
  | select(.destination.type == "Internet" and .resultingAction == "Allow")
  | { pod: .source.name, target: .destination.IPAddress, port: .port }
'
```

**Confirmed blocks — NetworkPolicy is working correctly:**

```bash
curl -s localhost:2709/probes | jq '
  .items[]
  | select(.expectedAction == "Deny" and .resultingAction == "Deny")
  | { from: .source.name, to: .destination.name, port: .port }
'
```

**What ports are actually listening on each pod** (from netstat, not just pod spec):

```bash
curl -s localhost:2709/probes | jq '.podNetworkingv2'
```

> If a pod listens on a port **not declared in its spec**, that container may have modified itself at runtime — a potential indicator of compromise.

**Summary counts:**

```bash
curl -s localhost:2709/probes | jq '
  {
    "unexpected_allow (findings)": [.items[] | select(.expectedAction=="Deny"  and .resultingAction=="Allow")] | length,
    "confirmed_deny":              [.items[] | select(.resultingAction=="Deny")]                               | length,
    "expected_allow":              [.items[] | select(.expectedAction=="Allow" and .resultingAction=="Allow")] | length,
    "probe_errors":                (.errors | length)
  }
'
```

---

## 9. Phase 7 — Understanding the Findings

### Finding 1 — MySQL can reach the internet (egress gap)

**What you see in the results:**

```json
{
  "from":     "mysql-0",
  "to":       "google.com",
  "port":     "80",
  "expected": "Deny",
  "result":   "Allow"
}
```

**Why it happens:** The `mysql-network-policy` only declares `policyTypes: [Ingress]`. In Kubernetes, a NetworkPolicy that lists only Ingress leaves egress **completely unrestricted** — this is intentional by the spec design, but it surprises most engineers who assume "I applied a NetworkPolicy, so the pod is locked down."

The policy controls *who can connect in to MySQL on 3306*. It says nothing about *where MySQL itself can connect out to*.

**Why it matters:**

- A compromised MySQL container can exfiltrate a database dump to an attacker's server over TCP 443
- It can download malware or a reverse shell over TCP 80
- It can contact command-and-control infrastructure

**The fix:** Add a separate `policyTypes: [Egress]` policy to restrict outbound connections. See [Phase 8](#10-phase-8--experiment-fix-the-mysql-egress-gap).

---

### Finding 2 — Any pod in `pet-clinic-app` can reach `java-app:8080`

**What you see:**

```json
{
  "from":     "monitoring-probe",
  "to":       "java-app-XXXXX",
  "port":     "8080",
  "expected": "Deny",
  "result":   "Allow"
}
```

**Why it happens:** There is no NetworkPolicy restricting ingress to `java-app` from other pods inside the same namespace. Any pod you deploy into `pet-clinic-app` — a sidecar, a debug pod, a compromised dependency — can freely probe the Spring Boot application on port 8080. This includes all Spring Actuator endpoints (`/actuator/env`, `/actuator/heapdump`, `/actuator/logfile`).

**Why it matters:** If a sidecar or monitoring agent is compromised, it can:

- Read application configuration including environment variables (database passwords, API keys) via `/actuator/env`
- Trigger heap dumps containing sensitive in-memory data
- Probe internal business logic endpoints

This may be acceptable for a legitimate monitoring tool — but it should be an explicit, deliberate decision, not an accident. A NetworkPolicy restricting java-app ingress to only trusted sources makes the intent explicit and verifiable.

---

### Confirmed Protection — `db-admin` is blocked from MySQL

**What you see:**

```json
{
  "from":     "db-admin",
  "to":       "mysql-0",
  "port":     "3306",
  "expected": "Deny",
  "result":   "Deny"
}
```

**Why it works:** `db-admin` lives in the `pet-clinic-db` namespace, which is labeled `name=pet-clinic-db`. The NetworkPolicy on mysql only permits ingress from namespaces labeled `name=pet-clinic-app`. Since `pet-clinic-db ≠ pet-clinic-app`, `db-admin` is blocked from MySQL — even though it lives in the **same namespace** as MySQL.

**Important Kubernetes behaviour this demonstrates:** NetworkPolicies match namespace **labels**, not namespace **names**. The policy does not say "allow from same namespace." It says "allow from any namespace carrying a specific label." You could label any namespace with `name=pet-clinic-app` and that namespace would gain access to MySQL. This is worth auditing periodically.

---

### Port Listening Cross-Check

```bash
curl -s localhost:2709/probes | jq '.podNetworkingv2'
```

Example output:

```json
{
  "java-app-XXXXX":  [{ "port": "8080", "ip": "0.0.0.0", "protocol": "TCP" }],
  "mysql-0":         [{ "port": "3306", "ip": "0.0.0.0", "protocol": "TCP" }],
  "monitoring-probe": [],
  "db-admin":        []
}
```

Kubesonde collects this via `netstat` running inside the debugger container and also reads the declared ports from the pod spec (`podConfigurationNetworking`). Compare the two fields:

- **`podNetworkingv2`** — what is *actually* listening at runtime
- **`podConfigurationNetworking`** — what the pod spec *declares*

A port that appears in `podNetworkingv2` but not in `podConfigurationNetworking` means a process inside the container is listening on an undeclared port. In production, this warrants investigation.

---

## 10. Phase 8 — Experiment: Fix the MySQL Egress Gap

### 10.1 Apply the egress deny policy

```bash
kubectl apply -f kube-configs/kubesonde-scenario/fix-mysql-egress.yaml
```

This adds a NetworkPolicy to `pet-clinic-db` that:

- **Blocks all egress** from mysql by default
- **Permits DNS** (UDP/TCP 53) so Kubernetes service discovery still works
- **Permits established connections** back to `pet-clinic-app` on port 3306

### 10.2 Verify the policy was applied

```bash
kubectl get networkpolicies -n pet-clinic-db
# mysql-network-policy   (existing — restricts ingress)
# mysql-deny-egress      (new — restricts egress)
```

### 10.3 Wait for kubesonde's re-probe loop

Kubesonde automatically re-runs all probes every **20 seconds**. Watch it happen in the logs:

```bash
kubectl logs -n kubesonde-system deployment/kubesonde-controller-manager | tail -20
```

### 10.4 Verify the fix

```bash
curl -s localhost:2709/probes | jq '
  .items[]
  | select(.source.name | startswith("mysql"))
  | select(.destination.type == "Internet")
  | { port: .port, result: .resultingAction }
'
```

MySQL → internet probes should now return `"result": "Deny"`.

### 10.5 Before/After comparison

| Probe | Before fix | After fix |
|-------|------------|-----------|
| mysql-0 → google.com:80 | **Allow** (finding) | **Deny** (fixed) |
| mysql-0 → google.com:443 | **Allow** (finding) | **Deny** (fixed) |
| mysql-0 → 8.8.8.8:53 UDP | Allow | Allow (DNS still permitted) |
| java-app → mysql-service:3306 | Allow | Allow (unaffected) |

---

## 11. Phase 9 — Visualize in the React UI

Kubesonde ships a React frontend that renders the JSON output as an interactive Cytoscape.js graph.

```bash
# Save current results
curl -s localhost:2709/probes > /tmp/petclinic-results.json

# Run the frontend locally
cd /path/to/kubesonde/frontend
npm install
npm run dev
```

Open `http://localhost:5173`, click **Upload JSON**, and select `/tmp/petclinic-results.json`.

**Reading the graph:**

| Visual element | Meaning |
|----------------|---------|
| Green edge | Probe matched expectation (expected Allow → Allow, or expected Deny → Deny) |
| Red edge | Mismatch — expected Deny but got Allow (a finding) |
| Node size | Proportional to total connection count |
| Internet node | Any probe that reached an external IP |

---

## 12. Troubleshooting

### Pods stuck in `Pending`

```bash
kubectl describe pod <name> -n <namespace>
```

If the event says `0/3 nodes are available`: reduce resource requests or increase `--memory` in `minikube start`. MySQL's node affinity and taint must also be satisfied — `minikube-m02` must exist with the `dedicated=db:NoSchedule` taint.

### NetworkPolicies not enforced (everything shows Allow)

```bash
kubectl get pods -n kube-system | grep calico
```

All `calico-node` pods must be `Running`. If they are not, recreate the cluster with `--cni=calico` explicitly. The most common cause is starting minikube without specifying the CNI, then trying to install Calico manually — Calico must be the CNI from the start.

### kubesonde error: "container not found (debugger)"

This is normal for the **first 10–30 seconds** after the CR is created — the ephemeral container is still being injected. If it persists beyond a minute, check:

```bash
kubectl describe pod <app-pod> -n pet-clinic-app | grep -A 10 "Ephemeral Containers"
```

If the debugger container shows `ImagePullBackOff`, the debugger image failed to pull. Override the image in your CR:

```yaml
spec:
  namespace: pet-clinic-app
  probe: all
  debuggerImage: ghcr.io/kubesonde/debugger:latest
```

### MySQL never becomes Ready

```bash
kubectl logs statefulset/mysql -n pet-clinic-db
```

If you see `ERROR 1396 (HY000): Operation CREATE USER failed` — the init script ran twice (PVC data is stale from a previous run). Delete the PVC and redeploy:

```bash
kubectl delete pvc mysql-data -n pet-clinic-db
kubectl delete pod mysql-0 -n pet-clinic-db
```

### java-app cannot connect to MySQL (CrashLoopBackOff)

Check namespace labels are set correctly:

```bash
kubectl get namespace pet-clinic-app --show-labels
# Must include: name=pet-clinic-app
```

If the label is missing, the NetworkPolicy will block all ingress to MySQL including from java-app:

```bash
kubectl label namespace pet-clinic-app name=pet-clinic-app
```

---

## 13. Quick Reference

Complete command sequence from zero to results:

```bash
# ── CLUSTER ──────────────────────────────────────────────────────────────────
minikube delete
minikube start --nodes=3 --cni=calico --driver=docker \
  --kubernetes-version=v1.28.0 --memory=3072 --cpus=2
minikube addons enable ingress metrics-server
kubectl taint nodes minikube-m02 dedicated=db:NoSchedule
kubectl wait --for=condition=Ready pods -l k8s-app=calico-node \
  -n kube-system --timeout=3m

# ── APPLICATION ──────────────────────────────────────────────────────────────
cd /path/to/javaAppK8s/spring-petclinic
kubectl create namespace pet-clinic-app
kubectl create namespace pet-clinic-db
kubectl label namespace pet-clinic-app name=pet-clinic-app
kubectl label namespace pet-clinic-db  name=pet-clinic-db
kubectl apply -f kube-configs/secret.yml -f kube-configs/secret-db.yml
kubectl apply -f kube-configs/mysql/resource-management.yml \
              -f kube-configs/mysql/configmap.yml \
              -f kube-configs/mysql/network-policy.yml \
              -f kube-configs/mysql/mysql.yml
kubectl rollout status statefulset/mysql -n pet-clinic-db --timeout=5m
kubectl apply -f kube-configs/java-app/resource-management.yml \
              -f kube-configs/java-app/configmap.yml \
              -f kube-configs/java-app/java.yml \
              -f kube-configs/java-app/hpa.yml
kubectl rollout status deployment/java-app -n pet-clinic-app --timeout=12m

# ── SCENARIO PODS ─────────────────────────────────────────────────────────────
kubectl apply -f kube-configs/kubesonde-scenario/extra-pods.yaml

# ── KUBESONDE ────────────────────────────────────────────────────────────────
kubectl apply -f /path/to/kubesonde/kubesonde.yaml
kubectl rollout status deployment/kubesonde-controller-manager \
  -n kubesonde-system --timeout=3m
kubectl apply -f kube-configs/kubesonde-scenario/kubesonde-cr-app.yaml
kubectl apply -f kube-configs/kubesonde-scenario/kubesonde-cr-db.yaml

# ── RESULTS ──────────────────────────────────────────────────────────────────
kubectl port-forward -n kubesonde-system \
  deployment/kubesonde-controller-manager 2709:2709 &

# Findings (unexpected Allow):
curl -s localhost:2709/probes | jq \
  '.items[] | select(.expectedAction=="Deny" and .resultingAction=="Allow")'

# Internet egress by pod:
curl -s localhost:2709/probes | jq \
  '.items[] | select(.destination.type=="Internet" and .resultingAction=="Allow") | {pod: .source.name, target: .destination.IPAddress, port}'

# ── FIX + VERIFY ─────────────────────────────────────────────────────────────
kubectl apply -f kube-configs/kubesonde-scenario/fix-mysql-egress.yaml
sleep 25   # wait for kubesonde's 20-second re-probe loop
curl -s localhost:2709/probes | jq \
  '.items[] | select(.source.name | startswith("mysql")) | {port, result: .resultingAction}'
```

---

### Scenario Files

All files referenced by this guide live in `kube-configs/kubesonde-scenario/`:

| File | Purpose |
|------|---------|
| `extra-pods.yaml` | Adds `monitoring-probe` and `db-admin` pods for the scenario |
| `kubesonde-cr-app.yaml` | Kubesonde CR targeting `pet-clinic-app` namespace |
| `kubesonde-cr-db.yaml` | Kubesonde CR targeting `pet-clinic-db` namespace |
| `fix-mysql-egress.yaml` | NetworkPolicy that closes the MySQL egress gap (Experiment) |
