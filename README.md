# Spring PetClinic on Kubernetes

A hands-on Kubernetes learning project using Spring PetClinic — a simple vet clinic app — as the workload. The focus is on deploying a real Java app on a local Minikube cluster with three nodes.

**Stack:** Spring Boot 4 · Java 17 · MySQL · Minikube (3 nodes)

---

## Architecture

```
  petclinic.local
       │
       ▼
  [ Ingress ]
       │
  Namespace: pet-clinic-app
  ┌─────────────────────────┐
  │  HPA (1–3 pods, 50% CPU)│
  │  PDB (min 1 always up)  │
  │  Deployment: java-app   │   → scheduled on any available worker node
  │  Service: NodePort 32000│
  └────────────┬────────────┘
               │ jdbc (cross-namespace DNS)
  Namespace: pet-clinic-db
  ┌─────────────────────────┐
  │  StatefulSet: mysql     │   → pinned to minikube-m02 (Node Affinity + Taint)
  │  Service: NodePort 30244│
  └─────────────────────────┘
```

### Cluster Nodes

```
minikube       → control-plane  (runs ingress controller, cluster components)
minikube-m02   → worker         (dedicated DB node — tainted, MySQL pinned here)
minikube-m03   → worker         (free worker — java-app schedules here)
```

| Resource | What it does |
|----------|-------------|
| Namespace | Isolates app and DB into separate scopes |
| Secret | Stores DB credentials (base64), shared across both namespaces |
| ConfigMap | Injects `application.properties` into the app pod, and `init.sql` into MySQL |
| Deployment | Runs the Spring Boot app (stateless, replaceable pods) |
| StatefulSet | Runs MySQL (stateful, stable identity) |
| Service (NodePort) | Exposes pods on a fixed port on the node |
| Ingress | Routes `petclinic.local` HTTP traffic to the app |
| HPA | Auto-scales the app between 1–3 replicas based on CPU |
| PersistentVolumeClaim | Stores MySQL data on disk — survives pod restarts |
| NetworkPolicy | Restricts MySQL access to only pods from `pet-clinic-app` namespace |
| LimitRange | Sets default/min/max CPU & memory per container in a namespace |
| ResourceQuota | Caps total CPU, memory, and object count for the whole namespace |
| Node Affinity | Forces MySQL pod to always run on `minikube-m02` |
| Taint & Toleration | `minikube-m02` rejects all pods except MySQL |
| PodDisruptionBudget | Guarantees at least 1 java-app pod stays running during maintenance |

---

## Docker Image

The image `belamean/kube-java-app:1.0.0` is already built and pushed to Docker Hub. The Deployment pulls it from there automatically — no local build needed to run this project.

**How it was built:**

```bash
./mvnw package -DskipTests                        # compile the jar
docker build -t belamean/kube-java-app:1.0.0 .   # build image from dockerfile
docker push belamean/kube-java-app:1.0.0          # push to Docker Hub
```

To release a new version after changing the code, bump the tag and update `image:` in `kube-configs/java-app/java.yml`:

```bash
./mvnw package -DskipTests
docker build -t belamean/kube-java-app:1.0.1 .
docker push belamean/kube-java-app:1.0.1
kubectl apply -f kube-configs/java-app/java.yml
```

---

## Prerequisites

```bash
# Start Minikube with 3 nodes and Calico CNI
minikube start --nodes 3 --cni calico --driver kvm2

# Enable required addons (must re-run after every minikube delete)
minikube addons enable ingress
minikube addons enable metrics-server
```

Verify all nodes are Ready before deploying:

```bash
kubectl get nodes
# NAME           STATUS   ROLES
# minikube       Ready    control-plane
# minikube-m02   Ready    worker
# minikube-m03   Ready    worker
```

---

## Deploy

```bash
# Namespaces
kubectl create namespace pet-clinic-app
kubectl create namespace pet-clinic-db

# Label namespaces (required for NetworkPolicy)
kubectl label namespace pet-clinic-app name=pet-clinic-app
kubectl label namespace pet-clinic-db  name=pet-clinic-db

# Taint the DB node so only MySQL can run there
kubectl taint nodes minikube-m02 dedicated=db:NoSchedule

# Secrets & ConfigMaps
kubectl apply -f kube-configs/secret.yml
kubectl apply -f kube-configs/secret-db.yml
kubectl apply -f kube-configs/mysql/configmap.yml
kubectl apply -f kube-configs/java-app/configmap.yml

# Workloads — wait for MySQL before starting the app
kubectl apply -f kube-configs/mysql/mysql.yml
kubectl rollout status statefulset/mysql -n pet-clinic-db
kubectl apply -f kube-configs/java-app/java.yml
kubectl apply -f kube-configs/java-app/ingress.yml
kubectl apply -f kube-configs/java-app/hpa.yml
kubectl apply -f kube-configs/java-app/pdb.yml

# Resource Management (LimitRange + ResourceQuota)
kubectl apply -f kube-configs/java-app/resource-management.yml
kubectl apply -f kube-configs/mysql/resource-management.yml

# NetworkPolicy
kubectl apply -f kube-configs/mysql/network-policy.yml
```

---

## Access

```bash
# Add to /etc/hosts (run this after every minikube delete — the IP changes)
sudo sed -i "s/.*petclinic.local/$(minikube ip) petclinic.local/" /etc/hosts
# or first time:
echo "$(minikube ip) petclinic.local" | sudo tee -a /etc/hosts
```

Then open `http://petclinic.local` or `http://$(minikube ip):32000`

---

## Node Affinity

MySQL is pinned to `minikube-m02` using Node Affinity. This ensures the DB always runs on a dedicated node, separate from the app.

The affinity block in `kube-configs/mysql/mysql.yml`:

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
      - matchExpressions:
        - key: kubernetes.io/hostname
          operator: In
          values:
          - minikube-m02
```

Verify MySQL is on the worker node:

```bash
kubectl get pods -o wide -n pet-clinic-db
# mysql-0 should show NODE = minikube-m02
```

---

## Taints & Tolerations

`minikube-m02` is tainted so only MySQL can run on it. Any pod without the matching toleration is rejected by the node.

Apply the taint:

```bash
kubectl taint nodes minikube-m02 dedicated=db:NoSchedule
```

MySQL has a matching toleration in `kube-configs/mysql/mysql.yml`:

```yaml
tolerations:
- key: "dedicated"
  operator: "Equal"
  value: "db"
  effect: "NoSchedule"
```

Verify no other pods land on `minikube-m02`:

```bash
kubectl get pods -o wide -A | grep minikube-m02
# only mysql-0 should appear
```

---

## Pod Disruption Budget (PDB)

PDB guarantees at least 1 java-app pod stays running during voluntary disruptions like node drain or rolling updates. It does not protect against node crashes.

File: `kube-configs/java-app/pdb.yml`

```bash
kubectl get pdb -n pet-clinic-app
# ALLOWED DISRUPTIONS = 1 means K8s can evict 1 pod safely
```

### Safe node drain procedure

Always follow this order to avoid chaos during maintenance:

```bash
# 1. set HPA min to 1 to prevent panic scaling during the drain
kubectl patch hpa java-app-hpa -n pet-clinic-app \
  -p '{"spec":{"minReplicas":1}}'

# 2. drain the node
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data --force

# 3. watch pods reschedule cleanly
kubectl get pods -o wide -n pet-clinic-app --watch

# 4. do your maintenance...

# 5. bring the node back
kubectl uncordon <node-name>

# 6. restore HPA
kubectl patch hpa java-app-hpa -n pet-clinic-app \
  -p '{"spec":{"minReplicas":2}}'
```

> **Important:** PDB requires at least one free worker node to reschedule the pod. With 3 nodes and one dedicated to MySQL, there is always a free node available during a drain.

---

## Persistent Storage

MySQL data is stored in a PersistentVolumeClaim, it survives pod restarts and rescheduling.

The `volumeClaimTemplates` in `mysql.yml` tells the StatefulSet to automatically provision a 1Gi volume and mount it at `/var/lib/mysql` (MySQL's data directory).

Verify the PVC was created after deploying:

```bash
kubectl get pvc -n pet-clinic-db
```

The StatefulSet will recreate the pod and reattach to the same volume automatically.

---

## Network Policy

By default any pod in the cluster can reach MySQL on port 3306. The NetworkPolicy in `kube-configs/mysql/network-policy.yml` restricts that to only pods from the `pet-clinic-app` namespace.

Before applying, label the namespaces so the policy can identify them:

```bash
kubectl label namespace pet-clinic-app name=pet-clinic-app
kubectl label namespace pet-clinic-db name=pet-clinic-db
```

Then apply:

```bash
kubectl apply -f kube-configs/mysql/network-policy.yml
```

Verify:

```bash
kubectl get networkpolicy -n pet-clinic-db
```

---

## Resource Management

`LimitRange` enforces per-container CPU/memory boundaries. `ResourceQuota` caps the namespace total. Together they prevent runaway resource consumption.

Files: `kube-configs/java-app/resource-management.yml` · `kube-configs/mysql/resource-management.yml`

```bash
# Check current usage vs quota
kubectl describe resourcequota app-resource-quota -n pet-clinic-app

# Test LimitRange: deploy a pod without resources — defaults get injected
kubectl run test-pod --image=nginx -n pet-clinic-app
kubectl get pod test-pod -n pet-clinic-app -o jsonpath='{.spec.containers[0].resources}'
kubectl delete pod test-pod -n pet-clinic-app
```
