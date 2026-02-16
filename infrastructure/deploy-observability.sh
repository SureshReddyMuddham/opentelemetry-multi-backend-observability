#!/bin/bash
# Deploy all observability backends on EKS cluster
# Prerequisites: EKS cluster running, kubectl configured, Helm installed

set -euo pipefail

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION="us-east-1"

echo "=== Step 1: Create Namespaces ==="
kubectl create namespace observability --dry-run=client -o yaml | kubectl apply -f -
kubectl create namespace elastic --dry-run=client -o yaml | kubectl apply -f -

echo "=== Step 2: Deploy Grafana LGTM ==="
kubectl apply -f k8s/grafana-lgtm.yaml
echo "Grafana LGTM deployed (admin/admin)"

echo "=== Step 3: Deploy SigNoz via Helm ==="
helm repo add signoz https://charts.signoz.io
helm repo update signoz
helm install signoz signoz/signoz -n observability \
  --set clickhouse.persistence.size=5Gi \
  --set frontend.service.type=LoadBalancer \
  --timeout 10m \
  --wait=false
echo "SigNoz deployed via Helm"

echo "=== Step 4: Deploy ECK Operator ==="
helm repo add elastic https://helm.elastic.co
helm repo update elastic
helm install eck-operator elastic/eck-operator \
  --namespace elastic \
  --timeout 5m \
  --wait=false
echo "ECK operator deployed"

echo "=== Step 5: Wait for ECK Operator ==="
sleep 30
kubectl wait --for=condition=Ready pod -l control-plane=elastic-operator -n elastic --timeout=120s || true

echo "=== Step 6: Deploy Elasticsearch + Kibana + APM Server ==="
kubectl apply -f k8s/elastic-stack.yaml
echo "Elastic stack deployed"

echo "=== Step 7: Build & Push App Image ==="
aws ecr create-repository --repository-name orders-api --region $REGION 2>/dev/null || true
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com
docker build --platform linux/amd64 -t ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/orders-api:latest app/
docker push ${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com/orders-api:latest
echo "App image pushed to ECR"

echo "=== Step 8: Wait for APM Server & Get Token ==="
echo "Waiting for Elasticsearch..."
kubectl wait --for=condition=Ready pod -l elasticsearch.k8s.elastic.co/cluster-name=elasticsearch -n elastic --timeout=300s || true
sleep 10

APM_TOKEN=$(kubectl get secret apm-server-apm-token -n elastic -o jsonpath='{.data.secret-token}' | base64 -d)
ES_PASS=$(kubectl get secret elasticsearch-es-elastic-user -n elastic -o jsonpath='{.data.elastic}' | base64 -d)
echo "APM Token: $APM_TOKEN"
echo "ES Password: $ES_PASS"

echo "=== Step 9: Deploy OTel Collector (fan-out) ==="
# Update the OTel collector config with actual APM token
sed "s/<APM_SECRET_TOKEN>/$APM_TOKEN/g" k8s/otel-collector.yaml | kubectl apply -f -
echo "OTel Collector deployed with fan-out to Grafana LGTM, SigNoz, Elastic APM"

echo "=== Step 10: Deploy Orders API ==="
sed "s/<ACCOUNT_ID>/$ACCOUNT_ID/g" k8s/app.yaml | kubectl apply -f -
echo "Orders API deployed"

echo "=== Step 11: Wait for All Pods ==="
sleep 30
kubectl get pods -A | grep -v kube-system

echo ""
echo "========================================="
echo "Observability Stack Deployed!"
echo "========================================="
NODE_IP=$(kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="ExternalIP")].address}')
echo ""
echo "Access URLs (use any worker node IP):"
echo "  Grafana:     http://${NODE_IP}:$(kubectl get svc grafana-lgtm -n observability -o jsonpath='{.spec.ports[0].nodePort}')"
echo "  SigNoz:      http://${NODE_IP}:$(kubectl get svc signoz -n observability -o jsonpath='{.spec.ports[0].nodePort}')"
echo "  Kibana:      https://${NODE_IP}:$(kubectl get svc kibana-kb-http -n elastic -o jsonpath='{.spec.ports[0].nodePort}')"
echo "  Orders API:  http://${NODE_IP}:$(kubectl get svc orders-api -n observability -o jsonpath='{.spec.ports[0].nodePort}')"
echo ""
echo "Credentials:"
echo "  Grafana:        admin / admin"
echo "  Kibana:         elastic / $ES_PASS"
echo "  SigNoz:         Create account on first visit"
