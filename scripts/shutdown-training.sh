#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTEXT="kind-kind"
INCLUDE_ARGOCD=false
INCLUDE_BACKSTAGE=true
TRAINING_ENV_FILE=""
ARGOCD_APP_NAMESPACE="argocd"
ARGOCD_APP_NAME="python-app"

usage() {
  cat <<'EOF'
Usage: shutdown-training.sh [--context <name>] [--argocd] [--no-argocd]
                           [--no-backstage] [--env-file <path>]

Scales down workloads used in this training environment:
- python-app deployment (namespace: python)
- ARC runner deployment and controller (namespace: actions-runner-system)
- Argo CD workloads (namespace: argocd) only if --argocd is set
- Backstage local container unless --no-backstage is set

By default, settings are loaded from:
- ../.env.training (relative to this script)
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
    --argocd)
      INCLUDE_ARGOCD=true
      shift
      ;;
    --no-backstage)
      INCLUDE_BACKSTAGE=false
      shift
      ;;
    --env-file)
      TRAINING_ENV_FILE="${2:-}"
      shift 2
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

load_training_env() {
  local env_file="$1"
  if [[ ! -f "$env_file" ]]; then
    return 0
  fi
  # shellcheck disable=SC1090
  set -a
  source "$env_file"
  set +a
  echo "Loaded training env: $env_file"
}

normalize_training_env() {
  # Backward compatibility for typo'd key while standardizing on GITHUB_TOKEN.
  if [[ -z "${GITHUB_TOKEN:-}" && -n "${GITHUB_TOkEN:-}" ]]; then
    export GITHUB_TOKEN="$GITHUB_TOkEN"
    echo "WARN: GITHUB_TOkEN is deprecated; use GITHUB_TOKEN in env file." >&2
  fi
}

if [[ -z "$TRAINING_ENV_FILE" ]]; then
  TRAINING_ENV_FILE="$SCRIPT_DIR/../.env.training"
fi
load_training_env "$TRAINING_ENV_FILE"
normalize_training_env

BACKSTAGE_CONTAINER_NAME="${BACKSTAGE_CONTAINER_NAME:-backstage-training}"
BACKSTAGE_IMAGE="${BACKSTAGE_IMAGE:-node:22-bookworm}"

kubectl_safe() {
  if ! kubectl --context "$CONTEXT" "$@"; then
    echo "WARN: command failed: kubectl --context $CONTEXT $*" >&2
  fi
}

warn_if_argocd_app_present() {
  if ! kubectl --context "$CONTEXT" get crd applications.argoproj.io >/dev/null 2>&1; then
    return 0
  fi
  if kubectl --context "$CONTEXT" -n "$ARGOCD_APP_NAMESPACE" get application "$ARGOCD_APP_NAME" >/dev/null 2>&1; then
    echo "WARN: Argo CD app exists: ${ARGOCD_APP_NAMESPACE}/${ARGOCD_APP_NAME}" >&2
    echo "      This repo deploys python-app directly via Helm from CI." >&2
    echo "      If Argo sync is run for this app, it may override deployed image tags." >&2
  fi
}

shutdown_backstage_container() {
  local ids=() found=()

  if [[ "$INCLUDE_BACKSTAGE" != "true" ]]; then
    echo "Skipping Backstage shutdown (--no-backstage)."
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "WARN: docker not found. Skipping Backstage shutdown." >&2
    return 0
  fi

  # 1) Preferred: explicit container name
  mapfile -t ids < <(docker ps -aq --filter "name=^/${BACKSTAGE_CONTAINER_NAME}$")

  # 2) Managed containers created by startup script labels
  if [[ "${#ids[@]}" -eq 0 ]]; then
    mapfile -t ids < <(docker ps -aq --filter "label=training.role=backstage")
  fi

  # 3) Fallback for manually started training containers
  if [[ "${#ids[@]}" -eq 0 ]]; then
    mapfile -t ids < <(
      docker ps -q \
        --filter "ancestor=${BACKSTAGE_IMAGE}" \
        --filter "publish=3000" \
        --filter "publish=7007"
    )
  fi

  mapfile -t found < <(printf '%s\n' "${ids[@]}" | awk 'NF' | sort -u)
  if [[ "${#found[@]}" -eq 0 ]]; then
    echo "Backstage container not found (name=$BACKSTAGE_CONTAINER_NAME, image=$BACKSTAGE_IMAGE)."
    return 0
  fi

  echo "Shutting down Backstage container(s)..."
  for cid in "${found[@]}"; do
    docker rm -f "$cid" >/dev/null 2>&1 || true
    echo "  removed: $cid"
  done
}

show_backstage_status() {
  if ! command -v docker >/dev/null 2>&1; then
    return 0
  fi

  docker ps --filter "name=^/${BACKSTAGE_CONTAINER_NAME}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  docker ps \
    --filter "label=training.role=backstage" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
}

echo "Using context: $CONTEXT"
warn_if_argocd_app_present

echo "Shutting down python-app workloads..."
kubectl_safe -n python scale deploy/python-app --replicas=0

echo "Shutting down ARC runner workloads..."
kubectl_safe -n actions-runner-system patch runnerdeployment/python-app-jeff-runners --type merge -p '{"spec":{"replicas":0}}'
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
  echo "Skipping Argo CD shutdown (use --argocd to enable)."
fi

shutdown_backstage_container

echo
echo "Current status snapshot:"
kubectl_safe -n python get deploy
kubectl_safe -n actions-runner-system get deploy
kubectl_safe -n actions-runner-system get runnerdeployment
if [[ "$INCLUDE_ARGOCD" == "true" ]]; then
  kubectl_safe -n argocd get deploy,sts
fi
show_backstage_status

echo "Shutdown sequence complete."
