#!/usr/bin/env bash
set -euo pipefail

CONTEXT="kind-kind"
INCLUDE_ARGOCD=true

usage() {
  cat <<'EOF'
Usage: shutdown-training.sh [--context <name>] [--no-argocd]

Scales down workloads used in this training environment:
- python-app deployment (namespace: python)
- ARC runner deployment and controller (namespace: actions-runner-system)
- Argo CD workloads (namespace: argocd) unless --no-argocd is set
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

echo "Using context: $CONTEXT"
echo "Shutting down python-app workloads..."
kubectl_safe -n python scale deploy/python-app --replicas=0

echo "Shutting down ARC runner workloads..."
kubectl_safe -n actions-runner-system scale deploy/actions-runner-controller --replicas=0
kubectl_safe -n actions-runner-system delete pod -l runner-deployment-name=python-app-jeff-runners --ignore-not-found=true --wait=false

if [[ "$INCLUDE_ARGOCD" == "true" ]]; then
  echo "Shutting down Argo CD workloads..."
  kubectl_safe -n argocd scale deploy/argocd-server --replicas=0
  kubectl_safe -n argocd scale deploy/argocd-repo-server --replicas=0
  kubectl_safe -n argocd scale deploy/argocd-applicationset-controller --replicas=0
  kubectl_safe -n argocd scale deploy/argocd-dex-server --replicas=0
  kubectl_safe -n argocd scale deploy/argocd-notifications-controller --replicas=0
  kubectl_safe -n argocd scale deploy/argocd-redis --replicas=0
  kubectl_safe -n argocd scale sts/argocd-application-controller --replicas=0
else
  echo "Skipping Argo CD shutdown (--no-argocd)."
fi

echo
echo "Current status snapshot:"
kubectl_safe -n python get deploy
kubectl_safe -n actions-runner-system get deploy
kubectl_safe -n actions-runner-system get runnerdeployment
if [[ "$INCLUDE_ARGOCD" == "true" ]]; then
  kubectl_safe -n argocd get deploy,sts
fi

echo "Shutdown sequence complete."
