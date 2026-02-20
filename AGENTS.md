# AGENTS.md

This file defines repository-specific operating instructions for Codex agents.

## Project Overview

- Flask app in `src/app.py`
- Docker image built from `Dockerfile`
- Helm chart for app in `charts/python-app`
- CI/CD workflow in `.github/workflows/ci.yaml`
- Local training environment uses kind context `kind-kind`

## Current Deploy Model (Important)

CI/CD is **direct deploy via Helm** from a self-hosted ARC runner.

- Trigger: pushes to `main` that change `src/**`
- Build job:
  - Creates short commit id: first 6 chars of `GITHUB_SHA`
  - Pushes image: `kittyiv/python-app-jeff:<short_sha>`
- CD job:
  - Runs on runner labels:
    - `self-hosted`, `linux`, `x64`, `python-app-jeff`
  - Builds in-cluster kubeconfig from runner service account
  - Installs Helm binary
  - Runs:
    - `helm upgrade --install python-app ./charts/python-app ... --set image.repository=kittyiv/python-app-jeff --set-string image.tag=<short_sha> --wait`

Do not reintroduce the old "commit values + argocd app sync" path unless explicitly requested.

## Kubernetes/Runtime Assumptions

- kube context: `kind-kind`
- app namespace: `python`
- app release: `python-app`
- ingress host: `python-app.test.com`
- runner namespace: `actions-runner-system`
- runner deployment CR: `python-app-jeff-runners`
- runner service account: `python-app-jeff-runners`

## ARC/RBAC Files

- `k8s/runnerdeployment.yaml`: RunnerDeployment and labels
- `k8s/runner-rbac.yaml`: service account + RoleBinding (`admin` in `python` namespace)

If runner deployment behavior changes, keep these files and workflow labels in sync.

## Ops Scripts

- `scripts/startup-training.sh`
- `scripts/shutdown-training.sh`

Both support:
- `--context <name>` (default `kind-kind`)
- `--no-argocd` (skip Argo CD scaling)

Runbook:
- `docs/shutdown-and-restart-runbook.md`

## Verification Commands

Use these as primary health checks:

```bash
kubectl get pods -n python --context kind-kind
kubectl get pods -n actions-runner-system --context kind-kind
kubectl get deploy python-app -n python --context kind-kind -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
curl -i http://python-app.test.com/api/v1/healthz
curl -i http://python-app.test.com/api/v1/info
```

## Common Pitfalls

1. Workflow not triggering:
   - `.github/workflows/ci.yaml` only triggers on `src/**` changes.
2. Pipeline success but app not updated:
   - Confirm deployed image tag in Kubernetes.
3. ARC runner CR patching can fail if webhook/controller is down.
   - Keep script behavior tolerant and avoid hard failures on partial shutdown states.
4. Never expose tokens/secrets in repo or logs.

## Secret Handling

- Never commit credentials.
- If a token/password is exposed, rotate immediately.
- Prefer env vars and GitHub Secrets over inline command values.

