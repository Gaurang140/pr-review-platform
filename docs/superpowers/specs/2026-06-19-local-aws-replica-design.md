# Local AWS replica + real-PR reviews — design spec

Date: 2026-06-19
Status: draft for review

## Summary

Run the existing PR-review platform entirely on a local machine instead of AWS, with no
change to the service architecture. The app still reviews real GitHub pull requests through
the existing GitHub App. The existing GitHub Actions CI/CD is reused, but runs on a
self-hosted runner and deploys to a local Kubernetes cluster instead of EKS. The OpenAI
dependency is swapped for Groq. AWS spend is zero.

The AWS infrastructure code (Terraform, EKS, ECR, k8s manifests) stays in the repo as the
documented "production architecture". Only the things that cost money (the cloud) are
swapped for local equivalents.

## Goals

- All seven app containers (gateway, webhook, orchestrator, reviewer, learner,
  webhook-worker, learner-worker) plus Postgres, Redis and MinIO run locally.
- Real PRs get reviewed: GitHub App delivers events through a tunnel to the local gateway,
  and the reviewer posts comments back on the PR.
- The existing GitHub Actions pipeline runs on the user's self-hosted runner and deploys to
  the local cluster (build -> local registry -> kind).
- Model is Groq, not OpenAI.
- Fits in 16 GB RAM.
- Repo reads as human-written, professional code.

## Non-goals / constraints

- No rewrite of the service architecture. Changes are additive or config-only.
- No automatic commits. The assistant prepares changes and a commit message; the user runs
  every commit.
- No deliberate misspellings in code; comments stay sparse, lowercase, casual, no AI tells
  (no em dashes, no over-explaining, no docstring-on-everything).
- The original AWS Terraform/CI/manifests stay intact as a showcase; local variants are
  added alongside, not in place of them.

## Architecture overview

Two independent flows, both pointed at the local machine.

Flow 1 — build & deploy (CI/CD):
`git push` -> GitHub Actions -> self-hosted runner -> `docker build` -> push to local
registry (replaces ECR) -> `kubectl` deploy to kind (replaces EKS).

Flow 2 — review a real PR (runtime):
PR opened -> GitHub App webhook -> cloudflared tunnel -> local gateway (HMAC verify) ->
webhook -> orchestrator (Groq) -> reviewer -> comment posted on the PR. Shared state in
local Postgres + Redis.

## Component mapping (AWS -> local)

| Original (AWS / cloud) | Local replacement | App code change |
|---|---|---|
| EKS | kind cluster | none |
| ECR | local registry (`registry:2`) | none |
| RDS PostgreSQL 15 | `postgres:15` container | none |
| ElastiCache Redis 7 | `redis:7` container | none |
| S3 bucket | MinIO | none |
| ALB (public URL) | cloudflared tunnel | none |
| GitHub Actions (GitHub-hosted) | GitHub Actions (self-hosted runner) | new local workflow |
| OpenAI gpt-4o-mini | Groq (`llama-3.3-70b-versatile`) | ~2 lines in orchestrator |
| GitHub App | unchanged; webhook URL -> tunnel | none |
| LangFuse | unchanged (free tier) or disabled | none |

## Stack layout

`.local-aws-stack/` stays at the workspace root as a reusable local cloud that any project
can deploy onto. Two layers:

```
.local-aws-stack/
  infra/    generic: kind + postgres + redis + minio + registry  (reusable, app-agnostic)
  apps/
    pr-review-platform/   this app's config + deploy overlay
    <future-app>/         add more projects later
```

Layer `infra/` is the "AWS services" stand-in and is shared. Layer `apps/<project>/` is the
per-project wiring (its ConfigMap/Secret/deploy script). pr-review-platform's overlay may
also be mirrored into the repo's own `local/` for a self-contained recruiter-facing
quickstart — decided in the plan.

## Components in detail

### Local cluster (kind) — replaces EKS
A single-node kind cluster named `pr-reviewer`, with port mappings for the gateway and the
MinIO console. The existing `infra/k8s/*.yaml` manifests are applied to it, with image refs
rewritten from ECR to the local registry. Defined in `.local-aws-stack/infra/`.

### Data plane (Postgres / Redis / MinIO) — replaces RDS / ElastiCache / S3
Deployed as in-cluster Deployments + Services so the app reaches them by service DNS exactly
as it reached AWS endpoints. Same engine versions as the Terraform (Postgres 15, Redis 7).
A one-shot Job creates the `ai-code-reviewer-reports` bucket in MinIO.

### Local registry — replaces ECR
A `registry:2` container wired to the kind cluster. The CI workflow pushes images here and
kind pulls from it, mirroring the ECR push/pull flow. (Fallback: `kind load docker-image`
if a registry proves fiddly.)

### Local CI workflow — self-hosted runner
A new workflow (e.g. `.github/workflows/service-ci-local.yml`) modelled on the existing
`service-ci.yml`, but `runs-on: self-hosted`, building images, pushing to the local
registry, and running `kubectl set image` against kind. The original AWS `service-ci.yml`
and per-service wrappers are left untouched.

### Tunnel + GitHub App
`cloudflared tunnel --url http://localhost:<gateway>` gives a public HTTPS URL. The GitHub
App's webhook URL is set to that URL + `/webhook/github`, keeping the same webhook secret so
the gateway's HMAC check passes. The reviewer authenticates outbound to the GitHub API with
the App's id + private key (user-supplied, rotated).

### LLM swap — Groq
In the orchestrator's model client (`services/orchestrator/graph.py` + settings), point the
OpenAI-compatible client at `https://api.groq.com/openai/v1`, read `GROQ_API_KEY`, and set
the model to a Groq model. The LangFuse instrumentation wrapper is kept; if LangFuse is
disabled the client falls back to a plain OpenAI-compatible client. Risk: minor param
incompatibilities between OpenAI and Groq — handled in the prompt/agent code if they surface.

### Local config overrides
A local ConfigMap + Secret (`.local-aws-stack/apps/pr-review-platform/`) that mirror
`infra/k8s/configmap.yaml` / `secret.yaml` but point `DATABASE_URL`, `REDIS_URL` and image
refs at the local services, and carry the user's own keys. The repo's original manifests are
not edited.

## Fixes & robustness

### Gateway bug
`services/gateway/models.py` imports `pydentic_settings` (typo for `pydantic_settings`) and
`services/gateway/main.py` shadows the imported `settings`. Fix both so the gateway starts.

### Secret hygiene
`infra/k8s/secret.yaml` holds real values but is already correctly handled: it is gitignored
(`.gitignore` line 236), not tracked, and never in git history. No rotation or history
rewrite needed. Remaining work is small: add a committed `infra/k8s/secret.yaml.example`
template documenting the required keys, and confirm the real file stays gitignored.

### Logging
Add a small shared structured-logging setup (e.g. `services/common/logging.py`) and wire it
into each service's startup so requests and errors are logged consistently. Additive, no
behavior change.

### Exception handling & retries
Add FastAPI exception handlers per service for clean error envelopes, and retry/backoff
around external calls (GitHub API, the model, Redis) in the worker/orchestrator paths.
Reviewer keeps its existing 422 summary-only fallback.

## README rewrite

Replace the long 16-phase Windows tutorial with a short, professional README:
- one-paragraph what-it-is + the architecture diagram,
- a "Run locally" quickstart (kind + the local scripts),
- a short "Deploy to AWS" section (kept for reference, condensed),
- a clear "local vs AWS" table.
Run the humanizer pass so the prose reads human. Target: concise reference, not a tutorial.

## Code style rules

Human-written feel everywhere touched: sparse comments only where a real dev would add one,
lowercase/casual tone, correct spelling, no em dashes, no AI vocabulary, no rule-of-three,
no docstring-on-everything. Match the surrounding code's existing style.

## Testing strategy

- Unit tests for any new helper code (logging setup, config loading, the Groq client wiring)
  with external calls faked.
- A smoke check: bring up the data plane + services on kind, confirm `/health` on the
  gateway and a simulated webhook flows through to a written `findings` row (demo mode),
  before wiring the live tunnel.
- Keep/adjust the existing per-service pytest suites; do not weaken them.

## What stays untouched

`infra/terraform/*`, the original `infra/k8s/*` manifests, `service-ci.yml` and the
per-service workflow wrappers, and the service business logic. These are the AWS showcase.

## Risks & open questions

- Groq model choice + any OpenAI/Groq param gaps (default: `llama-3.3-70b-versatile`).
- Tunnel choice: cloudflared (no signup) vs ngrok — default cloudflared.
- Local registry vs `kind load` — default local registry, fallback `kind load`.
- LangFuse: keep free-tier tracing or disable locally — default keep, optional.
- Real reviews require laptop + tunnel + runner to be running (inherent to local hosting).

## Out of scope

- Always-on public hosting (that is the AWS spend being avoided).
- Migrating to a different cluster tool (k3d/minikube) — kind is the choice.
- Rearchitecting services, queues, or the data model.

## Deliverables checklist

1. `.local-aws-stack/` restructured: `infra/` (kind + data plane + registry, reusable) and
   `apps/pr-review-platform/` (config + deploy overlay).
2. Local CI workflow on self-hosted runner -> local registry -> kind.
3. cloudflared tunnel + GitHub App webhook wiring docs.
4. Groq swap in the orchestrator.
5. Gateway bug fix.
6. Add `secret.yaml.example` template (real `secret.yaml` already gitignored — leave as is).
7. Shared logging + exception handling + retries.
8. Short rewritten README (local vs AWS).
9. Tests + smoke check.
