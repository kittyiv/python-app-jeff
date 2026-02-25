#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

CONTEXT="kind-kind"
INCLUDE_ARGOCD=true
INCLUDE_BACKSTAGE=true
TRAINING_ENV_FILE=""

usage() {
  cat <<'EOF'
Usage: startup-training.sh [--context <name>] [--no-argocd]
                          [--no-backstage] [--env-file <path>]

Scales up workloads used in this training environment:
- ARC runner controller + runner deployment
- python-app deployment
- Argo CD workloads (unless --no-argocd is set)
- Backstage local container (unless --no-backstage is set)

Backstage startup requires:
- AUTH_GITHUB_CLIENT_ID
- AUTH_GITHUB_CLIENT_SECRET

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

if [[ -z "$TRAINING_ENV_FILE" ]]; then
  TRAINING_ENV_FILE="$SCRIPT_DIR/../.env.training"
fi
load_training_env "$TRAINING_ENV_FILE"

BACKSTAGE_CONTAINER_NAME="${BACKSTAGE_CONTAINER_NAME:-backstage-training}"
BACKSTAGE_IMAGE="${BACKSTAGE_IMAGE:-node:22-bookworm}"
BACKSTAGE_APP_DIR="${BACKSTAGE_APP_DIR:-$HOME/backstage-app/backstage}"
BACKSTAGE_NODE_MODULES_VOLUME="${BACKSTAGE_NODE_MODULES_VOLUME:-backstage_node_modules}"

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

start_backstage_container() {
  local github_client_id github_client_secret

  if [[ "$INCLUDE_BACKSTAGE" != "true" ]]; then
    echo "Skipping Backstage startup (--no-backstage)."
    return 0
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "WARN: docker not found. Skipping Backstage startup." >&2
    return 0
  fi

  if [[ ! -d "$BACKSTAGE_APP_DIR" ]]; then
    echo "WARN: Backstage app directory not found: $BACKSTAGE_APP_DIR" >&2
    echo "      Set BACKSTAGE_APP_DIR to override. Skipping Backstage startup." >&2
    return 0
  fi

  github_client_id="${AUTH_GITHUB_CLIENT_ID:-}"
  github_client_secret="${AUTH_GITHUB_CLIENT_SECRET:-}"
  if [[ -z "$github_client_id" || -z "$github_client_secret" ]]; then
    echo "WARN: AUTH_GITHUB_CLIENT_ID / AUTH_GITHUB_CLIENT_SECRET not set." >&2
    echo "      Skipping Backstage startup." >&2
    return 0
  fi

  echo "Starting Backstage container..."
  docker rm -f "$BACKSTAGE_CONTAINER_NAME" >/dev/null 2>&1 || true

  if ! docker run -d \
    --name "$BACKSTAGE_CONTAINER_NAME" \
    --label training.role=backstage \
    --label training.managed-by=startup-training.sh \
    -e AUTH_GITHUB_CLIENT_ID="$github_client_id" \
    -e AUTH_GITHUB_CLIENT_SECRET="$github_client_secret" \
    -p 3000:3000 \
    -p 7007:7007 \
    -v "$BACKSTAGE_APP_DIR:/app" \
    -v "$BACKSTAGE_NODE_MODULES_VOLUME:/app/node_modules" \
    -w /app \
    "$BACKSTAGE_IMAGE" \
    bash -lc 'corepack enable >/dev/null 2>&1 || true; node .yarn/releases/yarn-4.4.1.cjs install --immutable; node .yarn/releases/yarn-4.4.1.cjs start'
  then
    echo "WARN: Backstage container failed to start." >&2
    return 0
  fi

  docker ps --filter "name=^/${BACKSTAGE_CONTAINER_NAME}$" \
    --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' || true
  echo "Backstage logs: docker logs -f $BACKSTAGE_CONTAINER_NAME"
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

start_backstage_container

echo "Startup sequence complete."
