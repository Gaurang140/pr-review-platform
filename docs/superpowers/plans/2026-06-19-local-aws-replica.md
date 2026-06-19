# Local AWS replica + real-PR reviews — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run the pr-review-platform entirely on a local machine (kind + Postgres + Redis + MinIO) instead of AWS, keep real PR reviews via the GitHub App + a tunnel, run CI on a self-hosted runner that deploys to kind, and swap OpenAI for Groq — with no change to the service architecture.

**Architecture:** A reusable local cloud lives at `.local-aws-stack/infra/` (kind=EKS, Postgres=RDS, Redis=ElastiCache, MinIO=S3, local registry=ECR). The pr-review-platform overlay (`pr-review-platform/local/`) deploys the existing k8s manifests onto it with image refs rewritten to the local registry. A cloudflared tunnel exposes the local gateway so the GitHub App can deliver real PR events; the reviewer posts comments back via the GitHub API. The orchestrator's LLM client points at Groq.

**Tech Stack:** kind, kubectl, Docker, `registry:2`, cloudflared, Python 3.12 (FastAPI/Celery/LangGraph), Groq (OpenAI-compatible), Alembic, pytest.

## Global Constraints

- No automatic commits. Every `git commit` step is run BY THE USER. The assistant stages nothing and commits nothing on its own; it only provides the exact command + message.
- No service-architecture rewrite. Changes are additive or config-only. Original `infra/terraform/*`, original `infra/k8s/*`, `service-ci.yml` and per-service workflow wrappers stay untouched.
- Human-written code style: sparse comments only where a real dev would add one, lowercase/casual tone, correct spelling, no em dashes, no AI vocabulary, no docstring-on-everything. Match surrounding style.
- Zero AWS spend. Everything runs locally.
- Work on a branch, never `main` (see Preflight).
- LLM = Groq, model `llama-3.3-70b-versatile` (override via `REVIEW_MODEL`).
- Secrets come from a gitignored `.env`; the k8s Secret is generated from it. `infra/k8s/secret.yaml` is already gitignored — leave it.
- The reusable cloud at `.local-aws-stack/` is the workspace root (not a git repo); repo changes are committed in `pr-review-platform`.

---

## Preflight (run once before Task 1)

- [ ] **P1: Confirm repo + branch.** In `pr-review-platform`, verify you are NOT on `main`, then create the work branch.

```bash
cd pr-review-platform
git rev-parse --abbrev-ref HEAD            # if this prints main/master, branch below
git switch -c local-aws-replica
```

- [ ] **P2: Install the one missing tool (cloudflared).**

```bash
brew install cloudflared
cloudflared --version                       # expect: cloudflared version X.Y.Z
```

- [ ] **P3: Confirm the rest of the toolchain is present.**

```bash
docker info >/dev/null && kind version && kubectl version --client && echo OK
```
Expected: `OK` printed (Docker daemon up, kind + kubectl present).

---

## Phase 1 — Reusable local cloud

### Task 1: Restructure `.local-aws-stack` and bring the cloud up

**Files:**
- Move: `.local-aws-stack/{kind-config.yaml,data-plane/,up.sh,down.sh}` → `.local-aws-stack/infra/`
- Create: `.local-aws-stack/infra/README.md`
- Remove from infra: `.local-aws-stack/app-overrides/`, `.local-aws-stack/build-and-deploy-app.sh` (these become the app overlay in Task 3)

**Interfaces:**
- Produces: a running kind cluster `pr-reviewer` with Services `postgres:5432`, `redis:6379`, `minio:9000`, and bucket `ai-code-reviewer-reports`. `infra/up.sh` and `infra/down.sh` manage it.

- [ ] **Step 1: Restructure the folders.**

```bash
cd .local-aws-stack
mkdir -p infra
git mv 2>/dev/null kind-config.yaml infra/ || mv kind-config.yaml infra/
mv data-plane up.sh down.sh infra/
mkdir -p apps
```

- [ ] **Step 2: Fix the path in `infra/up.sh`.** It references `$HERE/data-plane/` and `$HERE/app-overrides/`. Point data-plane at `infra/data-plane/` and drop the app-overrides apply (moves to the app overlay). Edit `infra/up.sh` so the config/secret apply lines are removed and only the cluster + data plane come up.

- [ ] **Step 3: Bring the cloud up.**

```bash
./infra/up.sh
```
Expected: cluster created, three Deployments roll out, `minio-make-bucket` Job completes.

- [ ] **Step 4: Verify the data plane is healthy.**

```bash
kubectl --context kind-pr-reviewer get pods
```
Expected: `postgres`, `redis`, `minio` pods `Running`/`Ready 1/1`; `minio-make-bucket` `Completed`.

- [ ] **Step 5: Write `infra/README.md`** — short: what the cloud is, `up.sh`/`down.sh`, the service endpoints. Keep it terse and human.

- [ ] **Step 6: Commit (USER RUNS THIS — `.local-aws-stack` is outside git; only commit if you choose to version it separately).** No repo commit for this task. Note progress and continue.

### Task 2: Add the local registry (ECR replacement)

**Files:**
- Create: `.local-aws-stack/infra/registry.sh`
- Modify: `.local-aws-stack/infra/up.sh` (call registry.sh; connect registry to the kind network)

**Interfaces:**
- Produces: a registry reachable at `localhost:5001` from the host and `kind-registry:5000` from inside the cluster. Images pushed to `localhost:5001/<name>` are pullable by kind.

- [ ] **Step 1: Write `infra/registry.sh`** following the kind "local registry" pattern: run a `registry:2` container named `kind-registry` on port 5001, connect it to the `kind` docker network, and apply the `local-registry-hosting` ConfigMap.

```bash
#!/usr/bin/env bash
set -euo pipefail
reg=kind-registry; port=5001
if [ "$(docker inspect -f '{{.State.Running}}' $reg 2>/dev/null || true)" != "true" ]; then
  docker run -d --restart=always -p "127.0.0.1:${port}:5000" --name $reg registry:2
fi
docker network connect kind $reg 2>/dev/null || true
kubectl --context kind-pr-reviewer apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: { name: local-registry-hosting, namespace: kube-public }
data:
  localRegistryHosting.v1: |
    host: "localhost:5001"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
```

- [ ] **Step 2: Wire it into `infra/up.sh`** so the registry comes up with the cloud (call `registry.sh` after the cluster exists).

- [ ] **Step 3: Verify push/pull works.**

```bash
docker pull hello-world && docker tag hello-world localhost:5001/hello-world:test
docker push localhost:5001/hello-world:test
curl -s localhost:5001/v2/_catalog          # expect: {"repositories":["hello-world"]}
```

- [ ] **Step 4: No repo commit (infra is outside git). Continue.**

---

## Phase 2 — App config & secrets

### Task 3: pr-review-platform overlay (`local/`) + secret generation from `.env`

**Files:**
- Create: `pr-review-platform/local/.env.example`
- Create: `pr-review-platform/local/configmap.local.yaml`
- Create: `pr-review-platform/local/gen-secret.sh`
- Create: `pr-review-platform/local/README.md`
- Symlink: `.local-aws-stack/apps/pr-review-platform` -> `../../pr-review-platform/local`
- Verify: `.gitignore` already ignores `.env` (lines 37-40) — confirm, do not duplicate.

**Interfaces:**
- Produces: `kubectl` Secret `app-secrets` + ConfigMap `app-config` in the cluster, built from `pr-review-platform/local/.env`. `gen-secret.sh` is idempotent.

- [ ] **Step 1: Write `local/.env.example`** (committed template, no real values). This is the user's key checklist.

```bash
# --- you generate these (real keys) ---
GROQ_API_KEY=
GITHUB_APP_ID=
GITHUB_WEBHOOK_SECRET=
# paste the .pem contents (multiline ok) or set GITHUB_APP_PRIVATE_KEY_FILE=path
GITHUB_APP_PRIVATE_KEY=
# optional tracing; leave blank to disable
LANGFUSE_PUBLIC_KEY=
LANGFUSE_SECRET_KEY=
# --- set for you (local, not secret) ---
DATABASE_URL=postgresql+asyncpg://dbadmin:localdevpassword@postgres:5432/codereviewer
REDIS_URL=redis://redis:6379/0
REVIEW_MODEL=llama-3.3-70b-versatile
```

- [ ] **Step 2: Write `local/configmap.local.yaml`** mirroring `infra/k8s/configmap.yaml` but with `REDIS_URL: redis://redis:6379/0` and the MinIO `AWS_*` values (from the earlier override). Service URLs unchanged.

- [ ] **Step 3: Write `local/gen-secret.sh`** — generate the k8s Secret from `.env` (no hand-editing of `secret.yaml`).

```bash
#!/usr/bin/env bash
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ctx=kind-pr-reviewer
[ -f "$here/.env" ] || { echo "create $here/.env from .env.example first"; exit 1; }
kubectl --context $ctx create secret generic app-secrets \
  --from-env-file="$here/.env" --dry-run=client -o yaml | kubectl --context $ctx apply -f -
kubectl --context $ctx apply -f "$here/configmap.local.yaml"
echo "app-secrets + app-config applied"
```

- [ ] **Step 4: Create the apps symlink so the reusable cloud registers this app.**

```bash
ln -sfn ../../pr-review-platform/local .local-aws-stack/apps/pr-review-platform
```

- [ ] **Step 5: Write `local/README.md`** — terse: copy `.env.example` to `.env`, fill keys, run `gen-secret.sh`, then `deploy.sh` (Task 6).

- [ ] **Step 6: Verify (with a throwaway `.env`).**

```bash
cp pr-review-platform/local/.env.example pr-review-platform/local/.env
bash pr-review-platform/local/gen-secret.sh
kubectl --context kind-pr-reviewer get secret app-secrets configmap/app-config
```
Expected: both exist. (Leave `.env` for later; it is gitignored.)

- [ ] **Step 7: Commit (USER RUNS THIS).**

```bash
git add local/.env.example local/configmap.local.yaml local/gen-secret.sh local/README.md
git commit -m "local: add reusable-cloud overlay for pr-review-platform"
```

---

## Phase 3 — Code fixes (repo)

### Task 4: Fix the gateway startup bug

**Files:**
- Modify: `services/gateway/models.py:1,3`
- Modify: `services/gateway/main.py:6,8`
- Modify: `services/gateway/requirements.txt` (add `pydantic-settings` if missing)
- Test: `services/gateway/tests/test_settings.py` (create)

**Interfaces:**
- Produces: `Settings` class in `gateway/models.py`; `settings` instance importable in `main.py`. App imports without error.

- [ ] **Step 1: Write the failing test.** Create `services/gateway/tests/test_settings.py`:

```python
def test_settings_imports_and_instantiates():
    from services.gateway.models import Settings
    s = Settings()
    assert hasattr(s, "github_webhook_secret")


def test_app_imports():
    from services.gateway import main
    assert main.app is not None
```

- [ ] **Step 2: Run it, expect failure** (ImportError on `pydentic_settings`).

```bash
cd services/gateway && python -m pytest tests/test_settings.py -v
```
Expected: FAIL — `ModuleNotFoundError: No module named 'pydentic_settings'`.

- [ ] **Step 3: Fix `models.py`.** Correct the import typo and rename the class:

```python
from pydantic_settings import BaseSettings

class Settings(BaseSettings):
    github_webhook_secret: str = ""

    class Config:
        env_file = ".env"
```

- [ ] **Step 4: Fix `main.py`** lines 6 + 8 to import the class and build one instance:

```python
from .models import Settings

settings = Settings()
```

- [ ] **Step 5: Ensure `pydantic-settings` is a dependency.** If absent from `services/gateway/requirements.txt`, add the line `pydantic-settings` and `pip install pydantic-settings`.

- [ ] **Step 6: Run tests, expect pass.**

```bash
cd services/gateway && python -m pytest tests/test_settings.py -v
```
Expected: 2 passed.

- [ ] **Step 7: Commit (USER RUNS THIS).**

```bash
git add services/gateway/models.py services/gateway/main.py services/gateway/requirements.txt services/gateway/tests/test_settings.py
git commit -m "fix(gateway): correct pydantic-settings import and settings instantiation"
```

### Task 5: Swap the orchestrator LLM to Groq

**Files:**
- Modify: `services/orchestrator/graph.py:6,10,40`
- Test: `services/orchestrator/tests/test_graph_client.py` (create)

**Interfaces:**
- Consumes: env `GROQ_API_KEY`, `REVIEW_MODEL`, optional `OPENAI_BASE_URL`, optional `LANGFUSE_PUBLIC_KEY`.
- Produces: `client` configured for Groq; `REVIEW_MODEL` used by `make_node`.

- [ ] **Step 1: Write the failing test.** Create `services/orchestrator/tests/test_graph_client.py`:

```python
import os

def test_client_targets_groq(monkeypatch):
    monkeypatch.setenv("GROQ_API_KEY", "test-key")
    monkeypatch.delenv("LANGFUSE_PUBLIC_KEY", raising=False)
    import importlib
    from services.orchestrator import graph
    importlib.reload(graph)
    assert "groq.com" in str(graph.client.base_url)
    assert graph.REVIEW_MODEL  # non-empty
```

- [ ] **Step 2: Run it, expect failure.**

```bash
cd services/orchestrator && python -m pytest tests/test_graph_client.py -v
```
Expected: FAIL (no `REVIEW_MODEL`, client not pointed at Groq).

- [ ] **Step 3: Edit `graph.py` top (lines 1-10 area).** Replace the hard `from langfuse.openai import OpenAI` / `client = OpenAI()` with env-driven, LangFuse-optional wiring:

```python
import os

if os.environ.get("LANGFUSE_PUBLIC_KEY"):
    from langfuse.openai import OpenAI
else:
    from openai import OpenAI

client = OpenAI(
    base_url=os.environ.get("OPENAI_BASE_URL", "https://api.groq.com/openai/v1"),
    api_key=os.environ.get("GROQ_API_KEY") or os.environ.get("OPENAI_API_KEY"),
)
REVIEW_MODEL = os.environ.get("REVIEW_MODEL", "llama-3.3-70b-versatile")
```

- [ ] **Step 4: Edit `make_node` (line ~40)** to use the configurable model:

```python
        response = client.chat.completions.create(
            model=REVIEW_MODEL,
            messages=[
                {"role": "system", "content": prompt},
                {"role": "user", "content": state["diff"]},
            ],
        )
```

- [ ] **Step 5: Run tests, expect pass.**

```bash
cd services/orchestrator && python -m pytest tests/test_graph_client.py -v
```
Expected: 1 passed.

- [ ] **Step 6: Commit (USER RUNS THIS).**

```bash
git add services/orchestrator/graph.py services/orchestrator/tests/test_graph_client.py
git commit -m "feat(orchestrator): drive review model via env, default to Groq"
```

---

## Phase 4 — Deploy the app onto the local cloud

### Task 6: App deploy script (build -> registry -> kind) + migration

**Files:**
- Create: `pr-review-platform/local/deploy.sh`

**Interfaces:**
- Consumes: the running cloud (Task 1-2), `app-secrets`/`app-config` (Task 3).
- Produces: all service Deployments running in kind; DB schema migrated.

- [ ] **Step 1: Write `local/deploy.sh`** — build each service from repo root, push to `localhost:5001`, apply the repo's k8s manifests with ECR refs rewritten to the local registry (via `sed | kubectl apply -f -`, never editing the repo files), run the migration job. Reuse the logic from the old `build-and-deploy-app.sh` but target the registry instead of `kind load`.

- [ ] **Step 2: Run it.**

```bash
bash pr-review-platform/local/deploy.sh
```
Expected: 5 images built + pushed, manifests applied, `db-migrate` Job `Completed`.

- [ ] **Step 3: Verify gateway health.**

```bash
kubectl --context kind-pr-reviewer port-forward svc/gateway 8080:8000 >/tmp/pf.log 2>&1 &
sleep 3 && curl -s localhost:8080/health
```
Expected: `{"status":"ok"}`.

- [ ] **Step 4: Commit (USER RUNS THIS).**

```bash
git add local/deploy.sh
git commit -m "local: add build-and-deploy script targeting the local registry + kind"
```

### Task 7: Demo-mode smoke test (signed webhook -> findings row)

**Files:**
- Create: `pr-review-platform/local/demo-pr.sh`

**Interfaces:**
- Consumes: running gateway (Task 6), `GITHUB_WEBHOOK_SECRET` from `.env`.
- Produces: proof the pipeline runs locally without GitHub (a `pull_requests` row reaches `reviewed`/`pending`).

- [ ] **Step 1: Write `local/demo-pr.sh`** — read `GITHUB_WEBHOOK_SECRET` from `.env`, build a minimal `pull_request opened` JSON body, compute `X-Hub-Signature-256` (HMAC-SHA256), and POST it to the port-forwarded gateway `/webhook/github`.

- [ ] **Step 2: Run it and check the DB.**

```bash
bash pr-review-platform/local/demo-pr.sh
kubectl --context kind-pr-reviewer exec deploy/postgres -- \
  psql -U dbadmin -d codereviewer -c "select id,status from pull_requests order by 1 desc limit 3;"
```
Expected: gateway returns `{"status":"received"}`; a `pull_requests` row exists. (Full review needs `GROQ_API_KEY` set; without it the row stays `pending` — that is fine for the smoke test.)

- [ ] **Step 3: Commit (USER RUNS THIS).**

```bash
git add local/demo-pr.sh
git commit -m "local: add offline demo-mode webhook smoke test"
```

---

## Phase 5 — Robustness (logging + exceptions)

### Task 8: Shared structured logging

**Files:**
- Create: `services/common/__init__.py`, `services/common/logging.py`
- Test: `services/common/tests/test_logging.py`
- Modify: each service `main.py` (one import + one `configure_logging()` call at startup)

**Interfaces:**
- Produces: `configure_logging(service_name: str) -> logging.Logger` — JSON-ish line logs to stdout, level from `LOG_LEVEL` (default INFO).

- [ ] **Step 1: Write the failing test** `services/common/tests/test_logging.py`:

```python
import logging
from services.common.logging import configure_logging

def test_configure_logging_returns_named_logger(monkeypatch):
    monkeypatch.setenv("LOG_LEVEL", "DEBUG")
    log = configure_logging("gateway")
    assert log.name == "gateway"
    assert log.level == logging.DEBUG
```

- [ ] **Step 2: Run it, expect failure** (module missing).

```bash
python -m pytest services/common/tests/test_logging.py -v
```

- [ ] **Step 3: Implement `services/common/logging.py`** — minimal stdlib logging config (no AI-style comments):

```python
import logging
import os

def configure_logging(service_name):
    level = os.environ.get("LOG_LEVEL", "INFO").upper()
    handler = logging.StreamHandler()
    handler.setFormatter(logging.Formatter(
        '{"ts":"%(asctime)s","svc":"' + service_name + '","lvl":"%(levelname)s","msg":"%(message)s"}'
    ))
    log = logging.getLogger(service_name)
    log.handlers = [handler]
    log.setLevel(level)
    log.propagate = False
    return log
```

- [ ] **Step 4: Run tests, expect pass.**

```bash
python -m pytest services/common/tests/test_logging.py -v
```

- [ ] **Step 5: Wire into each service.** In every `services/<svc>/main.py`, after the app is created add:

```python
from services.common.logging import configure_logging
log = configure_logging("<svc>")
```
(Replace `<svc>` per service. `services/common` must be importable — add it to each image build context if needed.)

- [ ] **Step 6: Commit (USER RUNS THIS).**

```bash
git add services/common services/*/main.py
git commit -m "feat(services): add shared structured logging"
```

### Task 9: Exception handlers + external-call retries

**Files:**
- Create: `services/common/errors.py`
- Test: `services/common/tests/test_errors.py`
- Modify: each service `main.py` (register handler); orchestrator/worker external calls (retry wrapper)

**Interfaces:**
- Produces: `install_error_handlers(app)` (FastAPI) returning JSON `{ "error": <type>, "detail": <msg> }` with 500; `with_retry(fn, attempts=3)` for GitHub/model/Redis calls.

- [ ] **Step 1: Write failing tests** `services/common/tests/test_errors.py`:

```python
from fastapi import FastAPI
from fastapi.testclient import TestClient
from services.common.errors import install_error_handlers, with_retry

def test_unhandled_error_becomes_json_500():
    app = FastAPI(); install_error_handlers(app)
    @app.get("/boom")
    def boom(): raise ValueError("nope")
    r = TestClient(app, raise_server_exceptions=False).get("/boom")
    assert r.status_code == 500 and r.json()["error"] == "ValueError"

def test_with_retry_succeeds_after_failures():
    calls = {"n": 0}
    def flaky():
        calls["n"] += 1
        if calls["n"] < 3: raise RuntimeError("temporary")
        return "ok"
    assert with_retry(flaky, attempts=3, delay=0) == "ok"
```

- [ ] **Step 2: Run, expect failure.**

```bash
python -m pytest services/common/tests/test_errors.py -v
```

- [ ] **Step 3: Implement `services/common/errors.py`:**

```python
import time
from fastapi import Request
from fastapi.responses import JSONResponse

def install_error_handlers(app):
    @app.exception_handler(Exception)
    async def _unhandled(request: Request, exc: Exception):
        return JSONResponse(status_code=500,
            content={"error": type(exc).__name__, "detail": str(exc)})

def with_retry(fn, attempts=3, delay=0.5):
    last = None
    for i in range(attempts):
        try:
            return fn()
        except Exception as e:
            last = e
            if i < attempts - 1:
                time.sleep(delay)
    raise last
```

- [ ] **Step 4: Run, expect pass.**

```bash
python -m pytest services/common/tests/test_errors.py -v
```

- [ ] **Step 5: Register handlers** — in each `services/<svc>/main.py` add `install_error_handlers(app)` after app creation. Wrap the GitHub API + model calls in orchestrator/reviewer and the Redis enqueue in webhook with `with_retry(...)`.

- [ ] **Step 6: Run each service's existing pytest suite to confirm nothing regressed.**

```bash
for s in gateway webhook orchestrator reviewer learner; do (cd services/$s && python -m pytest -q || true); done
```

- [ ] **Step 7: Commit (USER RUNS THIS).**

```bash
git add services/common services/*/main.py services/orchestrator services/reviewer services/webhook
git commit -m "feat(services): add error handlers and retry around external calls"
```

---

## Phase 6 — Real PR reviews

### Task 10: cloudflared tunnel + GitHub App webhook wiring

**Files:**
- Create: `pr-review-platform/local/tunnel.sh`
- Create: `pr-review-platform/local/GITHUB_APP_SETUP.md`

**Interfaces:**
- Produces: a public HTTPS URL forwarding to the local gateway; documented steps to point the GitHub App webhook at it.

- [ ] **Step 1: Write `local/tunnel.sh`** — port-forward `svc/gateway 8080:8000`, then `cloudflared tunnel --url http://localhost:8080`, and print the resulting URL with the reminder to append `/webhook/github`.

- [ ] **Step 2: Write `local/GITHUB_APP_SETUP.md`** — terse steps: create the GitHub App (permissions: Contents read, Pull requests read+write; subscribe to Pull request events), generate a private key (.pem), set the webhook secret to match `.env`, install it on the target repo, set the webhook URL to the tunnel URL + `/webhook/github`.

- [ ] **Step 3: Verify the tunnel reaches the gateway.**

```bash
bash pr-review-platform/local/tunnel.sh    # copy the printed https URL
curl -s <printed-url>/health               # expect: {"status":"ok"}
```

- [ ] **Step 4: Commit (USER RUNS THIS).**

```bash
git add local/tunnel.sh local/GITHUB_APP_SETUP.md
git commit -m "local: add cloudflared tunnel + GitHub App webhook setup guide"
```

### Task 11: Local CI workflow on the self-hosted runner

**Files:**
- Create: `.github/workflows/service-ci-local.yml`

**Interfaces:**
- Consumes: a registered self-hosted runner with Docker + kind + kubectl + the `pr-reviewer` kube context.
- Produces: on push to `local-aws-replica`, builds changed services, pushes to `localhost:5001`, `kubectl set image` on kind. Original `service-ci.yml` untouched.

- [ ] **Step 1: Write `.github/workflows/service-ci-local.yml`** — `on: push` (branch `local-aws-replica`, paths `services/**`), `runs-on: self-hosted`, matrix over the 5 services, steps: checkout, `docker build -f services/${{matrix.svc}}/Dockerfile -t localhost:5001/${{matrix.svc}}:${{github.sha}} .`, `docker push`, `kubectl --context kind-pr-reviewer set image deploy/${{matrix.svc}} ${{matrix.svc}}=localhost:5001/${{matrix.svc}}:${{github.sha}}`.

- [ ] **Step 2: Verify the runner is online.**

```bash
gh api repos/:owner/:repo/actions/runners --jq '.runners[] | {name,status}'
```
Expected: at least one runner `online`.

- [ ] **Step 3: Trigger + verify** — push a no-op change under `services/gateway/` and confirm the workflow runs on the self-hosted runner and the gateway deployment rolls.

```bash
kubectl --context kind-pr-reviewer rollout status deploy/gateway --timeout=180s
```

- [ ] **Step 4: Commit (USER RUNS THIS).**

```bash
git add .github/workflows/service-ci-local.yml
git commit -m "ci: add local deploy workflow for the self-hosted runner"
```

---

## Phase 7 — Docs & template

### Task 12: secret template + short README rewrite + final smoke

**Files:**
- Create: `infra/k8s/secret.yaml.example`
- Modify: `README.md` (replace the 16-phase tutorial)

- [ ] **Step 1: Write `infra/k8s/secret.yaml.example`** — the same keys as `secret.yaml` with placeholder values, committed, so the required keys are documented.

- [ ] **Step 2: Rewrite `README.md`** — concise: one-paragraph what-it-is, the architecture diagram reference, a "Run locally" quickstart (`.local-aws-stack/infra/up.sh` -> `local/gen-secret.sh` -> `local/deploy.sh` -> `local/tunnel.sh`), a condensed "Deploy to AWS" section, and a "local vs AWS" table. Human prose, no tutorial bloat.

- [ ] **Step 3: Humanizer pass on the README.** Use the humanizer skill on the new prose; remove any AI tells.

- [ ] **Step 4: Final end-to-end smoke (with real keys).** With `.env` filled, `gen-secret.sh` re-run, services rolled, tunnel up, open a real PR on the installed repo and confirm a review comment appears.

- [ ] **Step 5: Commit (USER RUNS THIS).**

```bash
git add README.md infra/k8s/secret.yaml.example
git commit -m "docs: rewrite README for local + AWS, add secret template"
```

---

## Notes for the executor

- If a service image can't import `services.common`, add a copy/`PYTHONPATH` step in that service's Dockerfile build context — do not restructure the services.
- Groq may reject some OpenAI params; if a call 400s, trim params in `make_node` rather than changing the graph shape.
- Real PR reviews require the laptop + tunnel + runner running. This is expected for local hosting.
