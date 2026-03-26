#!/bin/bash
set -euo pipefail

echo "=== Creating namespaces ==="
kubectl create namespace pet-clinic-app || echo "Namespace pet-clinic-app already exists"
kubectl create namespace pet-clinic-db  || echo "Namespace pet-clinic-db already exists"

echo "=== Labeling namespaces ==="
kubectl label namespace pet-clinic-app name=pet-clinic-app --overwrite
kubectl label namespace pet-clinic-db  name=pet-clinic-db --overwrite

echo "=== Tainting DB node ==="
kubectl taint nodes minikube-m02 dedicated=db:NoSchedule --overwrite || echo "Node already tainted"

echo "=== Applying Secrets & ConfigMaps ==="
kubectl apply -f kube-configs/secret.yml
kubectl apply -f kube-configs/secret-db.yml
kubectl apply -f kube-configs/mysql/configmap.yml
kubectl apply -f kube-configs/java-app/configmap.yml

echo "=== Deploying MySQL and waiting for it ==="
kubectl apply -f kube-configs/mysql/mysql.yml
kubectl rollout status statefulset/mysql -n pet-clinic-db

echo "=== Deploying Java app ==="
kubectl apply -f kube-configs/java-app/java.yml
kubectl apply -f kube-configs/java-app/ingress.yml
kubectl apply -f kube-configs/java-app/hpa.yml
kubectl apply -f kube-configs/java-app/pdb.yml

echo "=== Applying Resource Management ==="
kubectl apply -f kube-configs/java-app/resource-management.yml
kubectl apply -f kube-configs/mysql/resource-management.yml

echo "=== Applying NetworkPolicy ==="
kubectl apply -f kube-configs/mysql/network-policy.yml

echo "Deployment completed successfully!"
