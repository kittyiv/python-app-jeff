# Python App Training Runbook

This runbook is for this repo's local stack on `kind-kind`:
- App release: `python-app` (namespace `python`)
- GitHub runner controller: `actions-runner-controller` (namespace `actions-runner-system`)
- RunnerDeployment: `python-app-jeff-runners` (namespace `actions-runner-system`)
- Argo CD (optional for this flow): `argocd` (namespace `argocd`)

Current deploy flow in `.github/workflows/ci.yaml` uses direct Helm deploy from CI runner (not Argo CD sync).

Important:
- This repo deploys `python-app` via direct Helm in CI.
- If an Argo CD Application `argocd/python-app` is synced, it can override deployed image tags.
- Startup/shutdown scripts do not delete the app; they only warn.
- Recreate/list the app with `k8s/argocd-python-app.yaml` when needed.

## Prerequisites

- Docker Desktop running
- `kubectl`, `helm`, and `kind` installed
- Kube context set to `kind-kind`

```bash
kubectl config use-context kind-kind
```

## Option A: Quick Shutdown (keep cluster)

Use this when you want to pause training and restart fast later.

1. Preferred: use script (Argo CD workload scaling is opt-in):
```bash
./scripts/shutdown-training.sh
```

2. Scale app to zero manually:
```bash
kubectl -n python scale deploy/python-app --replicas=0
```

3. Stop self-hosted runner workload:
```bash
kubectl -n actions-runner-system scale runnerdeployment/python-app-jeff-runners --replicas=0
```

4. (Optional) Stop Argo CD workloads:
```bash
kubectl -n argocd scale deploy/argocd-server --replicas=0
kubectl -n argocd scale deploy/argocd-repo-server --replicas=0
kubectl -n argocd scale deploy/argocd-applicationset-controller --replicas=0
kubectl -n argocd scale deploy/argocd-dex-server --replicas=0
kubectl -n argocd scale deploy/argocd-notifications-controller --replicas=0
kubectl -n argocd scale deploy/argocd-redis --replicas=0
kubectl -n argocd scale sts/argocd-application-controller --replicas=0
```

5. Verify paused:
```bash
kubectl get deploy,sts -n python
kubectl get runnerdeployment -n actions-runner-system
kubectl get deploy,sts -n argocd
```

## Option A: Restart (keep cluster)

1. Preferred: use script (Argo CD workload scaling is opt-in):
```bash
./scripts/startup-training.sh
```

2. Start app manually:
```bash
kubectl -n python scale deploy/python-app --replicas=1
kubectl -n python rollout status deploy/python-app --timeout=180s
```

3. Start self-hosted runner:
```bash
kubectl -n actions-runner-system scale runnerdeployment/python-app-jeff-runners --replicas=1
kubectl -n actions-runner-system get pods -w
```

4. (Optional) Start Argo CD workloads back:
```bash
kubectl -n argocd scale deploy/argocd-server --replicas=1
kubectl -n argocd scale deploy/argocd-repo-server --replicas=1
kubectl -n argocd scale deploy/argocd-applicationset-controller --replicas=1
kubectl -n argocd scale deploy/argocd-dex-server --replicas=1
kubectl -n argocd scale deploy/argocd-notifications-controller --replicas=1
kubectl -n argocd scale deploy/argocd-redis --replicas=1
kubectl -n argocd scale sts/argocd-application-controller --replicas=1
```

5. Health checks:
```bash
kubectl get pods -n python
kubectl get pods -n actions-runner-system
curl -sS http://python-app.test.com/api/v1/healthz
curl -sS http://python-app.test.com/api/v1/info
```

## Option B: Full Shutdown (tear down local cluster)

Use this when you want to stop everything completely.

1. Delete kind cluster:
```bash
kind delete cluster
```

2. Stop Docker Desktop if desired.

## Option B: Full Restart (rebuild from scratch)

1. Start Docker Desktop.

2. Create kind cluster:
```bash
kind create cluster
kubectl config use-context kind-kind
```

3. Install ingress-nginx (required for `*.test.com` ingress access):
```bash
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/main/deploy/static/provider/kind/deploy.yaml
kubectl wait --namespace ingress-nginx --for=condition=ready pod --selector=app.kubernetes.io/component=controller --timeout=180s
```

4. Install Argo CD Helm chart only if needed for unrelated apps (not for `python-app` deploy sync):
```bash
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update
helm upgrade --install argocd argo/argo-cd \
  -n argocd \
  --create-namespace \
  -f charts/argocd/values-argo.yaml
```

Optional: restore the `python-app` Argo CD Application object for visibility in Argo UI:
```bash
kubectl apply -f k8s/argocd-python-app.yaml
kubectl get application python-app -n argocd
```

5. Install Actions Runner Controller:
```bash
helm repo add actions-runner-controller https://actions-runner-controller.github.io/actions-runner-controller
helm repo update
helm upgrade --install actions-runner-controller actions-runner-controller/actions-runner-controller \
  --namespace actions-runner-system \
  --create-namespace \
  --set authSecret.create=true \
  --set-string authSecret.github_token="$GITHUB_TOKEN" \
  --wait
```

6. Apply runner RBAC + RunnerDeployment from this repo:
```bash
kubectl apply -f k8s/runner-rbac.yaml
kubectl apply -f k8s/runnerdeployment.yaml
```

7. Deploy app once manually (after that, CI `cd` job keeps it updated):
```bash
TAG=<short_sha_tag_from_dockerhub_or_ci>
helm upgrade --install python-app ./charts/python-app \
  -n python \
  --create-namespace \
  --set image.repository=kittyiv/python-app-jeff \
  --set-string image.tag="$TAG"
```

8. Validate:
```bash
kubectl get pods -n python
kubectl get pods -n actions-runner-system
curl -sS http://python-app.test.com/api/v1/healthz
curl -sS http://python-app.test.com/api/v1/info
```

## Notes

- CI trigger is scoped to `src/**` changes.
- `cd` job runs on self-hosted runners labeled:
  - `self-hosted`, `linux`, `x64`, `python-app-jeff`
- Startup/shutdown scripts default to direct Helm flow; pass `--argocd` only when you intentionally want Argo CD workloads scaled.
- If app endpoint does not change after a successful pipeline, confirm the deployed image:
```bash
kubectl get deploy python-app -n python -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```
