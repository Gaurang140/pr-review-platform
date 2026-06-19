# PR Review Platform — AWS Deployment

This is the full guide for running the platform on AWS the way it was designed: EKS for the
services, RDS for Postgres, ElastiCache for Redis, ECR for images, and GitHub Actions doing
the build and deploy over OIDC (no AWS keys stored in GitHub).

Everything here is for macOS/Linux. Work through it top to bottom — the order matters, a few
steps depend on outputs from earlier ones.

The infrastructure lives in `infra/terraform/`, the Kubernetes manifests in `infra/k8s/`, and
the pipelines in `.github/workflows/`.

---

## What gets built

Terraform (`infra/terraform/`) provisions:

| Resource | Detail |
|---|---|
| VPC | `10.0.0.0/16`, two public subnets across two AZs |
| EKS | Kubernetes 1.32, one managed node group of `t3.medium` (2 nodes, scales 1–3) |
| RDS | PostgreSQL 15, `db.t3.micro`, database `codereviewer`, user `dbadmin` |
| ElastiCache | Redis 7, `cache.t3.micro`, single node |
| ECR | six repos — gateway, webhook, orchestrator, reviewer, learner, evaluate |
| S3 | bucket `ai-code-reviewer-reports` for stored reports |
| IAM | policy for the AWS Load Balancer Controller, attached to the node role |

The region defaults to `us-east-1` and the GitHub Actions workflows assume `us-east-1`, so
stay on that region unless you also edit the workflows.

---

## Architecture

```
GitHub (Pull Request opened)
        |
        v  HTTPS webhook
ALB ingress  ->  gateway   :8000   verify HMAC, route the event
                    |
                    v
                 webhook   :8001   persist the PR, queue a Celery job (Redis)
                    |
                    v
            webhook-worker         picks the job off the queue
                    |
                    v
              orchestrator :8002   LangGraph fans out 4 agents -> Groq
                    |                 static · security · style · architecture
                    v
               reviewer   :8003   aggregate findings, post the PR review
                    |
                    v  (on merge)
               learner    :8004   store patterns for next time

Backing services:  RDS PostgreSQL · ElastiCache Redis · S3
Observability:     Prometheus + Grafana · Langfuse (LLM traces)
```

Each service is FastAPI and exposes `/health` and `/metrics`. Only the orchestrator talks to
the LLM — it uses the OpenAI SDK pointed at Groq's OpenAI-compatible endpoint, model
`llama-3.3-70b-versatile` by default.

---

## Prerequisites

Install the CLIs:

```bash
brew install awscli terraform kubectl helm
```

Confirm they're all there:

```bash
aws --version
terraform -version
kubectl version --client
helm version
```

Accounts you need: an AWS account, a GitHub account, and a free Groq key from
[console.groq.com](https://console.groq.com/keys). Langfuse is optional (LLM tracing).

Point the AWS CLI at your account and confirm it:

```bash
aws configure          # or: aws configure --profile pr-review && export AWS_PROFILE=pr-review
aws sts get-caller-identity
```

---

## Step 1 — AWS identity for GitHub Actions

GitHub Actions authenticates to AWS through OIDC, so there are no long-lived access keys in
your GitHub secrets. This has to be done **before** Terraform, because the EKS cluster grants
admin access to this exact role by name (`github-actions-ai-reviewer`) — if the role doesn't
exist yet, the apply fails.

Create the OIDC provider (once per AWS account):

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

Create the role with a trust policy scoped to your repo. Replace `YOUR_GH_USER/YOUR_REPO`:

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

cat > /tmp/trust.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Federated": "arn:aws:iam::${ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": { "token.actions.githubusercontent.com:aud": "sts.amazonaws.com" },
      "StringLike": { "token.actions.githubusercontent.com:sub": "repo:YOUR_GH_USER/YOUR_REPO:*" }
    }
  }]
}
EOF

aws iam create-role \
  --role-name github-actions-ai-reviewer \
  --assume-role-policy-document file:///tmp/trust.json
```

Give it ECR push rights and permission to read the cluster (the in-cluster admin rights come
from the EKS access entry Terraform sets up):

```bash
aws iam attach-role-policy \
  --role-name github-actions-ai-reviewer \
  --policy-arn arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryPowerUser

cat > /tmp/eks-describe.json <<'EOF'
{ "Version": "2012-10-17", "Statement": [{ "Effect": "Allow", "Action": "eks:DescribeCluster", "Resource": "*" }] }
EOF

aws iam put-role-policy \
  --role-name github-actions-ai-reviewer \
  --policy-name eks-describe \
  --policy-document file:///tmp/eks-describe.json
```

Save the role ARN — you'll need it for the GitHub secrets in Step 4:

```bash
aws iam get-role --role-name github-actions-ai-reviewer --query Role.Arn --output text
```

---

## Step 2 — Provision the infrastructure

```bash
cd infra/terraform

terraform init

terraform plan \
  -var="cluster_name=pr-review-platform" \
  -var="db_password=CHANGE_ME_strong_password" \
  -var="environment=production"

terraform apply \
  -var="cluster_name=pr-review-platform" \
  -var="db_password=CHANGE_ME_strong_password" \
  -var="environment=production"
```

This takes roughly 15 minutes — EKS and RDS are the slow parts. State is stored locally in
this directory by default; if more than one person will run Terraform, add an S3 backend block
to `main.tf` and re-run `terraform init`.

When it finishes, save the outputs — later steps need the RDS and Redis endpoints:

```bash
terraform output
```

You'll use `rds_endpoint`, `redis_endpoint`, and `eks_cluster_endpoint`. The bucket name and
ECR repos are fixed by the config.

---

## Step 3 — Create the GitHub App

This is the identity the bot uses to read diffs and post reviews.

1. GitHub → Settings → Developer settings → GitHub Apps → **New GitHub App**
2. Name it (e.g. `PR Review Platform`)
3. Webhook URL: put a placeholder for now (e.g. `https://example.com`) — the real URL doesn't
   exist until the ingress is up in Step 7, you'll come back and fix it in Step 9
4. Webhook secret: generate one with `openssl rand -hex 32` and keep it
5. Permissions: **Pull requests** read & write, **Contents** read-only
6. Subscribe to events: **Pull request**
7. Create the app, then **generate a private key** and download the `.pem`
8. Install the app on the repos you want reviewed

Keep four things: the **App ID**, the **webhook secret**, the **`.pem` file**, and the install.

---

## Step 4 — GitHub Actions secrets

Repo → Settings → Secrets and variables → Actions. Add exactly these three:

| Secret | Value |
|---|---|
| `AWS_ROLE_ARN` | the `github-actions-ai-reviewer` ARN from Step 1 |
| `AWS_ACCOUNT_ID` | your 12-digit account ID |
| `EKS_CLUSTER_NAME` | `pr-review-platform` |

Nothing else goes here. The app credentials, database URL and LLM key live in a Kubernetes
secret instead (Step 6), not in GitHub.

---

## Step 5 — Connect kubectl to the cluster

```bash
aws eks update-kubeconfig --name pr-review-platform --region us-east-1
kubectl get nodes
```

Wait for two nodes in `Ready` state before moving on.

---

## Step 6 — Cluster config and secrets

The services read two objects: a ConfigMap (`app-config`) for non-secret wiring and a Secret
(`app-secrets`) for credentials. The ConfigMap is part of the Kustomize AWS overlay and gets
applied in Step 7. The Secret is created here, by hand, because secrets are never committed.

**Point the overlay's ConfigMap at your Redis.** Edit `infra/k8s/overlays/aws/configmap.yaml`
and set `REDIS_URL` to the `redis_endpoint` Terraform gave you, keeping the `redis://` prefix
and `:6379/0` suffix. (`REVIEW_MODEL` and the service URLs are already in there — that's why
they're not in the secret below.)

**Create the secret** from your real values — credentials only. The orchestrator prefers
`GROQ_API_KEY`, but some manifests reference `OPENAI_API_KEY`, so set both to the same Groq key
(Groq is OpenAI-API compatible). The private key goes in straight from the `.pem` file so the
multi-line format survives:

```bash
RDS_HOST=$(cd infra/terraform && terraform output -raw rds_endpoint)

kubectl create secret generic app-secrets \
  --from-literal=DATABASE_URL="postgresql+asyncpg://dbadmin:CHANGE_ME_strong_password@${RDS_HOST%:*}/codereviewer" \
  --from-literal=GITHUB_APP_ID="YOUR_APP_ID" \
  --from-literal=GITHUB_WEBHOOK_SECRET="YOUR_WEBHOOK_SECRET" \
  --from-file=GITHUB_APP_PRIVATE_KEY=path/to/your-app.pem \
  --from-literal=GROQ_API_KEY="gsk_your_groq_key" \
  --from-literal=OPENAI_API_KEY="gsk_your_groq_key" \
  --from-literal=LANGFUSE_PUBLIC_KEY="pk-lf-... (optional)" \
  --from-literal=LANGFUSE_SECRET_KEY="sk-lf-... (optional)"
```

> The `DATABASE_URL` uses the `postgresql+asyncpg://` driver — that's what the services and the
> Alembic migration expect. `${RDS_HOST%:*}` strips the `:5432` Terraform appends so the URL
> doesn't end up with a doubled port. `infra/k8s/secret.example.yaml` lists the same keys if you'd
> rather fill in a file and `kubectl apply` it.

---

## Step 7 — First deploy (one-time bootstrap)

The CI/CD pipeline only ever runs `kubectl set image` — it updates the image on a Deployment
that already exists. It does **not** create Deployments. So the first time, you create them by
hand from the Kustomize AWS overlay. After this, every push deploys on its own (Step 8).

The overlay points images at a fixed ECR account. Point it at yours — one edit to
`infra/k8s/overlays/aws/kustomization.yaml` (the `newName:` lines):

```bash
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
sed -i '' "s/789438508565/${ACCOUNT_ID}/g" infra/k8s/overlays/aws/kustomization.yaml
# Linux: drop the '' after -i
```

Recreate the migration job, apply the overlay, and wait for the migration:

```bash
kubectl delete job db-migrate --ignore-not-found
kubectl apply -k infra/k8s/overlays/aws
kubectl wait --for=condition=complete job/db-migrate --timeout=180s
```

`kubectl apply -k` builds the overlay (Deployments, Services, ConfigMap, LoadBalancer, ingress,
autoscaler) and applies it in one shot.

The ingress uses an ALB, which needs the AWS Load Balancer Controller running in the cluster.
The IAM policy for it is already created by Terraform and attached to the node role — install
the controller itself with Helm:

```bash
helm repo add eks https://aws.github.io/eks-charts && helm repo update

helm install aws-load-balancer-controller eks/aws-load-balancer-controller \
  -n kube-system \
  --set clusterName=pr-review-platform \
  --set serviceAccount.create=true
```

Check the rollout and grab the public address:

```bash
kubectl get pods
kubectl get ingress gateway-ingress     # wait ~2–3 min for ADDRESS to appear
```

> The images are tagged `:latest` and won't exist in your ECR until the first pipeline run, so
> some pods may sit in `ImagePullBackOff` here. That's expected — the push in Step 8 builds and
> pushes them, and the Deployments recover on their own.

---

## Step 8 — Deploy by pushing

From here the pipeline owns deploys. Push to `main`:

```bash
git push origin main
```

Each service has its own workflow (`gateway.yml`, `webhook.yml`, …) that only fires when files
under that service's directory change, so unrelated services don't rebuild. Each one calls the
shared `service-ci.yml`, which:

1. runs the tests
2. assumes the AWS role over OIDC, logs in to ECR
3. builds the image, tags it with the commit SHA and `latest`, pushes both
4. runs `kubectl set image deployment/<service> ...` with the SHA-tagged image

Watch it in the **Actions** tab. On a pull request only the tests run; build and deploy happen
on push to `main`.

---

## Step 9 — Point the webhook at the cluster

Now that the ingress has an address:

```bash
kubectl get ingress gateway-ingress
```

Back in the GitHub App settings, set the Webhook URL to:

```
http://YOUR_INGRESS_ADDRESS/webhook/github
```

Mark it Active and save. (The ingress serves plain HTTP on port 80 out of the box — put it
behind ACM/HTTPS before any real use.)

---

## Step 10 — Monitoring

The services already expose Prometheus metrics at `/metrics`, and `monitoring/` holds the
scrape config and a ready-made Grafana dashboard. Install the stack with Helm:

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install monitoring prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  --set grafana.adminPassword=admin
```

The deployments carry `prometheus.io/scrape` annotations, and `monitoring/prometheus.yml`
documents the exact targets (`gateway:8000`, `webhook:8001`, `orchestrator:8002`,
`reviewer:8003`, `learner:8004`) if you want to drive scraping by static config instead.

Open Grafana and import the dashboard:

```bash
kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80
# http://localhost:3000  — login admin / admin
```

In Grafana → Dashboards → Import, upload `monitoring/graphana-dashboard.json` and pick the
Prometheus data source. It has a row of panels per service (request rate, p99 latency, error
rate) plus an overall-health row.

LLM traces show up in Langfuse automatically when the Langfuse keys are set in the secret.

---

## Step 11 — End-to-end test

1. Make sure the app is installed on a test repo and the pods are `Running`
2. Open a PR with something obviously off — a hardcoded password, an `eval()` call
3. Within a minute the bot posts a review with its findings

If nothing shows up, check the gateway logs first — it's where webhook delivery and signature
problems surface:

```bash
kubectl logs -l app=gateway --tail=100
```

---

## Day-to-day access

| Thing | How |
|---|---|
| Public URL | `kubectl get ingress gateway-ingress` |
| Grafana | `kubectl port-forward -n monitoring svc/monitoring-grafana 3000:80` |
| Service logs | `kubectl logs -f -l app=<service>` |
| Pod status | `kubectl get pods` |
| Langfuse | [us.cloud.langfuse.com](https://eu.cloud.langfuse.com) |

---

## Troubleshooting

**Pods stuck in `ImagePullBackOff`** — the image isn't in your ECR yet, or the manifests still
point at the wrong account. Confirm the account rewrite in Step 7 ran, then push to `main` so
the pipeline builds and pushes the images.

**Pods in `CreateContainerConfigError`** — `app-config` or `app-secrets` is missing or missing a
key. Both must exist before the pods start: `kubectl get configmap app-config` and
`kubectl get secret app-secrets`.

**Ingress has no ADDRESS** — the Load Balancer Controller isn't running. Check
`kubectl get pods -n kube-system | grep load-balancer`.

**`kubectl set image` fails in the pipeline with "deployments not found"** — the one-time
bootstrap in Step 7 didn't run. The pipeline can't create Deployments, only update them.

**Webhook deliveries failing** — recheck the webhook URL ends in `/webhook/github` and the
secret in the GitHub App matches `GITHUB_WEBHOOK_SECRET` in the cluster secret.

---

## Cost

Running 24/7 in `us-east-1`, very roughly:

| Resource | Approx / month |
|---|---|
| EKS control plane | ~$73 |
| 2× t3.medium nodes | ~$60 |
| RDS db.t3.micro | ~$15 |
| ElastiCache cache.t3.micro | ~$12 |
| ALB + S3 + traffic | ~$20 |
| **Total** | **~$180** |

Groq has a free tier; Langfuse has a free tier.

---

## Teardown

Order matters. The Load Balancer Controller creates ALBs and security groups that Terraform
doesn't track, so delete the Kubernetes objects that own them first — otherwise `terraform
destroy` fails on a dependency violation.

```bash
kubectl delete -k infra/k8s/overlays/aws
# this removes the ingress and gateway-lb, so the ALB and NLB get released.
# give AWS a minute to tear down the load balancers, then:

cd infra/terraform
terraform destroy \
  -var="cluster_name=pr-review-platform" \
  -var="db_password=CHANGE_ME_strong_password" \
  -var="environment=production"
```

RDS is created with `skip_final_snapshot`, so destroying it drops the data with no backup.
Export anything you need first.
