# OpenTelemetry with Multiple Observability Backends

Production-ready Node.js application instrumented with OpenTelemetry, deployed on AWS EKS, sending traces, metrics, and logs to **three observability backends** simultaneously via an OTel Collector fan-out pattern.

## Architecture

```
                    ┌─────────────────┐
                    │  Node.js App    │
                    │  (Orders API)   │
                    │  + OTel SDK     │
                    └────────┬────────┘
                             │ OTLP (HTTP/gRPC)
                    ┌────────▼────────┐
                    │  OpenTelemetry  │
                    │  Collector      │
                    │  (fan-out)      │
                    └──┬──────┬───┬───┘
           ┌───────────┘      │   └───────────┐
           ▼                  ▼               ▼
  ┌────────────────┐ ┌──────────────┐ ┌──────────────────┐
  │ Grafana LGTM   │ │   SigNoz     │ │ Elastic Stack    │
  │                │ │              │ │                  │
  │ - Grafana UI   │ │ - ClickHouse │ │ - Elasticsearch  │
  │ - Tempo        │ │ - Query Svc  │ │ - Kibana         │
  │ - Loki         │ │ - Frontend   │ │ - APM Server     │
  │ - Prometheus   │ │ - ZooKeeper  │ │ - ECK Operator   │
  └────────────────┘ └──────────────┘ └──────────────────┘
    Traces ✓            Traces ✓          Traces ✓
    Metrics ✓           Metrics ✓         Metrics ✓
    Logs ✓              Logs ✓            Logs ✓
```

## Observability Backends

| Backend | Traces | Metrics | Logs | UI |
|---------|--------|---------|------|----|
| **Grafana LGTM** | Tempo | Prometheus | Loki | Grafana |
| **SigNoz** | ClickHouse | ClickHouse | ClickHouse | SigNoz UI |
| **Elastic Stack** | APM Server | APM Server | Elasticsearch | Kibana |

## Project Structure

```
├── app/                              # Node.js Orders API
│   ├── Dockerfile
│   ├── package.json
│   └── src/
│       ├── instrumentation.js        # OTel SDK setup (traces, metrics, logs)
│       └── server.js                 # Express API with custom OTel metrics
├── docker-compose.yaml               # Local deployment (all backends)
├── otel-collector-config.yaml        # OTel Collector config (Docker Compose)
├── infrastructure/
│   ├── setup-eks.sh                  # AWS EKS cluster provisioning
│   └── deploy-observability.sh       # Deploy all backends on EKS
└── k8s/                              # Kubernetes manifests
    ├── namespaces.yaml
    ├── app.yaml                      # Orders API deployment
    ├── otel-collector.yaml           # OTel Collector with fan-out config
    ├── grafana-lgtm.yaml             # Grafana LGTM all-in-one
    ├── elastic-stack.yaml            # Elasticsearch + Kibana + APM (ECK CRDs)
    └── signoz.yaml                   # SigNoz (deployed via Helm chart)
```

## Node.js Application

The Orders API is a real-time Express.js application with full OpenTelemetry instrumentation:

- **Auto-instrumentation** for HTTP, Express, DNS via `@opentelemetry/auto-instrumentations-node`
- **Custom metrics**: `orders_total`, `order_value_dollars`, `active_orders`
- **Custom spans** with attributes for each API operation
- **Structured JSON logging** correlated with trace context

### API Endpoints

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/health` | Health check |
| GET | `/api/orders` | List all orders |
| POST | `/api/orders` | Create an order |
| PUT | `/api/orders/:id` | Update order status |
| DELETE | `/api/orders/:id` | Delete an order |
| POST | `/api/simulate` | Generate bulk test traffic |

## Deployment Options

### Option 1: Docker Compose (Local)

```bash
docker-compose up -d
```

Access:
- Orders API: http://localhost:3000
- Grafana: http://localhost:3001 (admin/admin)
- SigNoz: http://localhost:3301
- Kibana: http://localhost:5601

### Option 2: AWS EKS

#### Prerequisites
- AWS CLI configured
- kubectl installed
- Helm installed
- Docker installed

#### Step 1: Provision EKS Cluster
```bash
./infrastructure/setup-eks.sh
```
This creates: VPC, subnets, IGW, security groups, IAM roles, EKS cluster, 3 self-managed worker nodes (t3.medium), EBS CSI driver.

#### Step 2: Deploy Observability Stack
```bash
./infrastructure/deploy-observability.sh
```
This deploys: Grafana LGTM, SigNoz (Helm), ECK operator + Elasticsearch + Kibana + APM Server, OTel Collector, Orders API.

#### Step 3: Generate Traffic
```bash
NODE_IP=<worker-node-public-ip>
APP_PORT=<orders-api-nodeport>

# Create orders
curl -X POST http://$NODE_IP:$APP_PORT/api/orders \
  -H "Content-Type: application/json" \
  -d '{"customer":"Alice","items":["Laptop"],"total":999}'

# Simulate bulk traffic
curl -X POST http://$NODE_IP:$APP_PORT/api/simulate \
  -H "Content-Type: application/json" \
  -d '{"count":50}'
```

## OTel Collector Fan-Out Configuration

The collector receives OTLP telemetry from the app and exports to all three backends:

```yaml
exporters:
  otlphttp/lgtm:
    endpoint: http://grafana-lgtm:4318       # Grafana LGTM
  otlp/signoz:
    endpoint: signoz-otel-collector:4317      # SigNoz
  otlp/elastic:
    endpoint: http://apm-server:8200          # Elastic APM

service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [otlphttp/lgtm, otlp/signoz, otlp/elastic]
    metrics:
      receivers: [otlp]
      exporters: [otlphttp/lgtm, otlp/signoz, otlp/elastic]
    logs:
      receivers: [otlp]
      exporters: [otlphttp/lgtm, otlp/signoz, otlp/elastic]
```

## EKS Access URLs

After deployment, access services via worker node public IP + NodePort:

| Service | Default Credentials |
|---------|-------------------|
| Grafana | admin / admin |
| Kibana | elastic / (auto-generated, see deploy script output) |
| SigNoz | Create account on first visit |

## Tech Stack

- **Runtime**: Node.js 20, Express.js
- **Telemetry**: OpenTelemetry SDK, OTel Collector Contrib
- **Backends**: Grafana LGTM, SigNoz, Elasticsearch + Kibana + APM Server
- **Infrastructure**: AWS EKS, EC2 (self-managed nodes), ECR, EBS CSI
- **Orchestration**: Kubernetes, Helm, Docker Compose
- **IaC**: Bash scripts with AWS CLI
