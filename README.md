# Spring PetClinic on Kubernetes

A hands-on Kubernetes learning project using Spring PetClinic — a simple vet clinic app — as the workload. The focus is on deploying a real Java app on a local Minikube cluster.

**Stack:** Spring Boot 4 · Java 17 · MySQL · Minikube

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
  │  Deployment: java-app   │
  │  Service: NodePort 32000│
  └────────────┬────────────┘
               │ jdbc (cross-namespace DNS)
  Namespace: pet-clinic-db
  ┌─────────────────────────┐
  │  StatefulSet: mysql     │
  │  Service: NodePort 30244│
  └─────────────────────────┘
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
minikube start
minikube addons enable ingress
minikube addons enable metrics-server
```

---

## Deploy

```bash
# Namespaces
kubectl create namespace pet-clinic-app
kubectl create namespace pet-clinic-db

# Secrets & ConfigMaps
kubectl apply -f kube-configs/secret.yml
kubectl apply -f kube-configs/secret-db.yml
kubectl apply -f kube-configs/mysql/configmap.yml
kubectl apply -f kube-configs/java-app/configmap.yml

# Workloads
kubectl apply -f kube-configs/mysql/mysql.yml
kubectl rollout status statefulset/mysql -n pet-clinic-db
kubectl apply -f kube-configs/java-app/java.yml
kubectl apply -f kube-configs/java-app/ingress.yml
kubectl apply -f kube-configs/java-app/hpa.yml

# Resource Management (LimitRange + ResourceQuota)
kubectl apply -f kube-configs/java-app/resource-management.yml
kubectl apply -f kube-configs/mysql/resource-management.yml
```

---

## Access

```bash
# Add to /etc/hosts
echo "$(minikube ip) petclinic.local" | sudo tee -a /etc/hosts
```

Then open `http://petclinic.local` or `http://$(minikube ip):32000`

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

