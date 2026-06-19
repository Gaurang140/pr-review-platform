# PR Review Platform

An agentic code review system that reviews GitHub pull requests automatically. When a PR is
opened, a LangGraph multi-agent workflow reads the diff, runs four reviewers over it (static
analysis, security, style, architecture) and posts the findings back as a PR review.

It's five FastAPI microservices on Kubernetes, backed by Postgres, Redis and S3. The production
target is AWS — EKS, RDS, ElastiCache, ECR — and that setup lives in `infra/`. For local work
the same services run in a [kind](https://kind.sigs.k8s.io/) cluster on your machine, with a
self-hosted GitHub Actions runner.

---

## How a review happens

![System Architecture Diagram](ARCHITECTURE/Architecture%20Diagram.png)

```
GitHub PR opened
      |
      v  webhook
  gateway   :8000   verify the HMAC signature, route the event
      |
      v
  webhook   :8001   save the PR, queue a job on Redis
      |
      v
 webhook-worker     pull the job off the queue
      |
      v
 orchestrator :8002 LangGraph runs 4 agents in parallel -> Groq
      |               static · security · style · architecture
      v
  reviewer  :8003   merge the findings, post the PR review
      |
      v  (on merge)
  learner   :8004   store the patterns to sharpen future reviews
```

Only the orchestrator calls the LLM. It uses the OpenAI SDK pointed at Groq's
OpenAI-compatible endpoint, so the model is swappable through `REVIEW_MODEL`.

---

## Services

| Service | Port | Role |
|---|---|---|
| gateway | 8000 | webhook entry point, HMAC verify, routing |
| webhook | 8001 | persists the PR, queues review jobs on Redis |
| orchestrator | 8002 | LangGraph agent fan-out, calls Groq |
| reviewer | 8003 | aggregates findings, posts the PR review |
| learner | 8004 | stores review patterns in Postgres |
| webhook-worker | — | Celery worker for the webhook queue |
| learner-worker | — | Celery worker for the learning queue |

Backing services: Postgres 15, Redis 7, MinIO (the local S3 stand-in).

---

## Run it locally

Everything runs in a local kind cluster — no AWS account, no cost. Postgres stands in for RDS,
Redis for ElastiCache, MinIO for S3.

### Prerequisites

```bash
brew install kind kubectl
```

Docker Desktop or OrbStack needs to be running.

### 1. Start the cluster

```bash
bash local/infra/up.sh
```

Creates the `pr-reviewer` kind cluster and brings up Postgres, Redis and MinIO inside it.

### 2. Fill in your keys

```bash
cp local/.env.example local/.env
```

The only thing you have to set to get a review working is the Groq key:

```
GROQ_API_KEY=gsk_...          # free at console.groq.com/keys
```

For real PR reviews also set `GITHUB_APP_ID` and `GITHUB_WEBHOOK_SECRET`, and drop the GitHub
App `.pem` file into `local/` (it's gitignored). Everything else in `.env.example` — database
URL, service URLs, MinIO creds — is already filled in for local use.

### 3. Push the secrets into the cluster

```bash
bash local/sync-secret.sh
```

Reads `local/.env` (and any `.pem` in `local/`) and writes them into the `app-secrets`
Kubernetes secret the services read from.

### 4. Build and deploy

```bash
bash local/deploy.sh
```

Builds the five service images, loads them into kind, runs the DB migration and rolls
everything out.

### 5. Check it

```bash
kubectl get pods
curl http://localhost:8080/health
```

The gateway is published on `localhost:8080` by a NodePort (kind maps the host port to it),
so no port-forward is needed.

---

## CI/CD on a self-hosted runner

`deploy-local.yml` runs on a self-hosted runner registered to the repo. It triggers on push to
`main` or `local-aws-replica` and runs `local/deploy.sh`, so every push redeploys the cluster
and shows a green check in the Actions tab.

To register the runner: repo Settings → Actions → Runners → New self-hosted runner, follow the
macOS (arm64) steps, then start it with `./run.sh`.

---

## Real PR reviews

GitHub needs a public URL to deliver webhooks to your machine. A quick tunnel does it:

```bash
brew install cloudflared
cloudflared tunnel --url http://localhost:8080
```

Take the `trycloudflare.com` URL it prints and set it as the Webhook URL in your GitHub App:

```
https://<your-tunnel>.trycloudflare.com/webhook/github
```

Mark it Active. Now opening a PR on any repo the app is installed on triggers a full review.

---

## Production on AWS

The full AWS walkthrough is in [DOCUMENTATION/aws-deployment.md](DOCUMENTATION/aws-deployment.md) —
OIDC setup, Terraform, the cluster bootstrap, and the monitoring stack.

```
infra/
  terraform/             VPC, EKS, ECR, RDS, ElastiCache, S3
  k8s/
    base/                env-agnostic Deployments, Services, migration job
    overlays/local/      local images, NodePort, local config  (kind)
    overlays/aws/        ECR images, LoadBalancer + ALB ingress, autoscaler  (EKS)
```

The same base manifests drive both environments through Kustomize overlays —
`kubectl apply -k infra/k8s/overlays/local` locally, `overlays/aws` on EKS.

`.github/workflows/service-ci.yml` builds each service, pushes to ECR and rolls it out on EKS
with `kubectl set image`, authenticating to AWS over OIDC — no AWS keys stored in GitHub.

---

## Environment variables

| Variable | Where it comes from |
|---|---|
| `GROQ_API_KEY` | [console.groq.com/keys](https://console.groq.com/keys), free |
| `GITHUB_APP_ID` | GitHub App → General → App ID |
| `GITHUB_WEBHOOK_SECRET` | set when you create the GitHub App |
| `GITHUB_APP_PRIVATE_KEY` | the `.pem` from the app, saved in `local/` |
| `REVIEW_MODEL` | LLM model, defaults to `llama-3.3-70b-versatile` |
| `LANGFUSE_PUBLIC_KEY` / `LANGFUSE_SECRET_KEY` | [langfuse.com](https://us.cloud.langfuse.com), optional tracing |

The rest of `local/.env.example` is pre-filled for local development.

---

## Stack

- FastAPI + Uvicorn
- LangGraph for the multi-agent orchestration
- Groq `llama-3.3-70b-versatile` (swappable via `REVIEW_MODEL`)
- Celery + Redis
- SQLAlchemy async + asyncpg + Alembic
- Prometheus + Grafana, Langfuse for LLM tracing
- Kubernetes — kind locally, EKS in production
