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
