#!/usr/bin/env bash
set -euo pipefail

CONTEXT="kind-kind"
INCLUDE_ARGOCD=true

usage() {
  cat <<'EOF'
Usage: startup-training.sh [--context <name>] [--no-argocd]

Scales up workloads used in this training environment:
- ARC runner controller + runner deployment
- python-app deployment
- Argo CD workloads (unless --no-argocd is set)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --context)
      CONTEXT="${2:-}"
      shift 2
      ;;
    --no-argocd)
      INCLUDE_ARGOCD=false
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

kubectl_safe() {
  if ! kubectl --context "$CONTEXT" "$@"; then
    echo "WARN: command failed: kubectl --context $CONTEXT $*" >&2
  fi
}

wait_for_arc_webhook() {
  local i endpoint_ip
  for i in {1..30}; do
    endpoint_ip="$(kubectl --context "$CONTEXT" -n actions-runner-system get endpoints actions-runner-controller-webhook -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null || true)"
    if [[ -n "$endpoint_ip" ]]; then
      return 0
    fi
    sleep 2
  done
  echo "WARN: ARC webhook endpoint did not become ready in time." >&2
  return 1
}

echo "Using context: $CONTEXT"

echo "Starting ARC runner controller..."
kubectl_safe -n actions-runner-system scale deploy/actions-runner-controller --replicas=1
kubectl_safe -n actions-runner-system rollout status deploy/actions-runner-controller --timeout=180s
wait_for_arc_webhook || true

echo "Starting ARC runner deployment..."
kubectl_safe -n actions-runner-system patch runnerdeployment/python-app-jeff-runners --type merge -p '{"spec":{"replicas":1}}'
for i in {1..60}; do
  ready_count="$(kubectl --context "$CONTEXT" -n actions-runner-system get pods -l runner-deployment-name=python-app-jeff-runners -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null | grep -c '^true$' || true)"
  if [[ "$ready_count" -ge 1 ]]; then
    break
  fi
  sleep 3
done
if [[ "${ready_count:-0}" -lt 1 ]]; then
  echo "WARN: Runner pod did not report ready within timeout." >&2
fi

if [[ "$INCLUDE_ARGOCD" == "true" ]]; then
  echo "Starting Argo CD workloads..."
  kubectl_safe -n argocd scale deploy/argocd-server --replicas=1
  kubectl_safe -n argocd scale deploy/argocd-repo-server --replicas=1
  kubectl_safe -n argocd scale deploy/argocd-applicationset-controller --replicas=1
  kubectl_safe -n argocd scale deploy/argocd-dex-server --replicas=1
  kubectl_safe -n argocd scale deploy/argocd-notifications-controller --replicas=1
  kubectl_safe -n argocd scale deploy/argocd-redis --replicas=1
  kubectl_safe -n argocd scale sts/argocd-application-controller --replicas=1
else
  echo "Skipping Argo CD startup (--no-argocd)."
fi

echo "Starting python-app..."
kubectl_safe -n python scale deploy/python-app --replicas=1
kubectl_safe -n python rollout status deploy/python-app --timeout=300s

echo
echo "Current status snapshot:"
kubectl_safe -n python get deploy,pods
kubectl_safe -n actions-runner-system get deploy,runnerdeployment,pods
if [[ "$INCLUDE_ARGOCD" == "true" ]]; then
  kubectl_safe -n argocd get deploy,sts,pods
fi

echo "Endpoint checks:"
kubectl_safe get ingress -n python
if command -v curl >/dev/null 2>&1; then
  curl -fsS http://python-app.test.com/api/v1/healthz || true
  echo
  curl -fsS http://python-app.test.com/api/v1/info || true
  echo
fi

echo "Startup sequence complete."
