#!/bin/bash
set -euo pipefail

INSTANCE_ID=""
HOST=""
PLATFORM_URL="${PLATFORM_URL:-https://www.clawstaffing.com}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_SERVICE_TOKEN="${PLATFORM_SERVICE_TOKEN:-${PROVISIONER_PLATFORM_TOKEN:-}}"
CURRENT_STEP=""
CONFIG_REPO_DIR=""
RELEASE_WORKTREE_ROOT=""
RELEASE_CONFIG_DIR=""
ROLLBACK_READY=0
ROLLBACK_IN_PROGRESS=0
ROLLBACK_SNAPSHOT_DIR=""
ROLLBACK_GATEWAY_TAG=""
ROLLBACK_WORKSPACE_TAG=""
SSH_USER="openclaw"
TARGET_ENV_FILE=""

build_failure_details() {
  local exit_code="$1"

  jq -nc \
    --arg host "${HOST:-}" \
    --arg step "${CURRENT_STEP:-unknown}" \
    --argjson exitCode "$exit_code" \
    '{
      step: $step,
      exitCode: $exitCode
    } + (if $host != "" then {host: $host} else {} end)'
}

api_get() {
  curl -sf "$PLATFORM_URL/api/instances/$INSTANCE_ID" \
    -H "Authorization: Bearer $PLATFORM_SERVICE_TOKEN" \
    -H "X-Claw-Service: provisioner"
}

api_patch() {
  curl -sf -X PATCH "$PLATFORM_URL/api/instances/$INSTANCE_ID" \
    -H "Authorization: Bearer $PLATFORM_SERVICE_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Claw-Service: provisioner" \
    -d "$1"
}

report_event() {
  local event_type="$1"
  local details="${2:-}"
  curl -sf -X POST "$PLATFORM_URL/api/instances/$INSTANCE_ID/events" \
    -H "Authorization: Bearer $PLATFORM_SERVICE_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Claw-Service: provisioner" \
    -d "{\"eventType\": \"$event_type\", \"details\": $details}" > /dev/null 2>&1 || true
}

cleanup_release_artifacts() {
  if [[ -n "${TARGET_ENV_FILE:-}" && -f "${TARGET_ENV_FILE}" ]]; then
    rm -f "$TARGET_ENV_FILE"
  fi

  cleanup_release_config_worktree "$CONFIG_REPO_DIR"
}

rollback_release() {
  ROLLBACK_IN_PROGRESS=1
  CURRENT_STEP="rollback"

  ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" \
    bash -s "$ROLLBACK_SNAPSHOT_DIR" "$ROLLBACK_GATEWAY_TAG" "$ROLLBACK_WORKSPACE_TAG" <<'REMOTE_SCRIPT'
set -euo pipefail

SNAPSHOT_DIR="$1"
ROLLBACK_GATEWAY_TAG="$2"
ROLLBACK_WORKSPACE_TAG="$3"
ENV_PATH="$HOME/openclaw/.env"

if [[ ! -d "$SNAPSHOT_DIR" ]]; then
  echo "Rollback snapshot not found: $SNAPSHOT_DIR"
  exit 1
fi

if [[ -f "$SNAPSHOT_DIR/openclaw.env" ]]; then
  cp "$SNAPSHOT_DIR/openclaw.env" "$ENV_PATH"
fi

if [[ -f "$ENV_PATH" ]]; then
  if docker image inspect "$ROLLBACK_GATEWAY_TAG" >/dev/null 2>&1; then
    if grep -q '^OPENCLAW_GATEWAY_IMAGE=' "$ENV_PATH"; then
      sed -i.bak "s|^OPENCLAW_GATEWAY_IMAGE=.*|OPENCLAW_GATEWAY_IMAGE=$ROLLBACK_GATEWAY_TAG|" "$ENV_PATH"
    else
      printf "\nOPENCLAW_GATEWAY_IMAGE=%s\n" "$ROLLBACK_GATEWAY_TAG" >> "$ENV_PATH"
    fi
  fi

  if docker image inspect "$ROLLBACK_WORKSPACE_TAG" >/dev/null 2>&1; then
    if grep -q '^WORKSPACE_SYNC_IMAGE=' "$ENV_PATH"; then
      sed -i.bak "s|^WORKSPACE_SYNC_IMAGE=.*|WORKSPACE_SYNC_IMAGE=$ROLLBACK_WORKSPACE_TAG|" "$ENV_PATH"
    else
      printf "\nWORKSPACE_SYNC_IMAGE=%s\n" "$ROLLBACK_WORKSPACE_TAG" >> "$ENV_PATH"
    fi
  fi

  rm -f "$ENV_PATH.bak"
fi

if [[ -f "$SNAPSHOT_DIR/openclaw-home.tar.gz" ]]; then
  rm -rf "$HOME/.openclaw"
  tar -xzf "$SNAPSHOT_DIR/openclaw-home.tar.gz" -C "$HOME"
fi

cd "$HOME/openclaw"
docker compose up -d --force-recreate openclaw-gateway template-runtime caddy

if [[ -f .env ]] && grep -qE '^GIT_WORKSPACE_REPO=.+' .env; then
  docker compose --profile sync up -d workspace-sync
else
  if docker compose ps --format '{{.Name}}' 2>/dev/null | grep -q workspace-sync; then
    docker compose stop workspace-sync 2>/dev/null || true
    docker compose rm -f workspace-sync 2>/dev/null || true
  fi
fi
REMOTE_SCRIPT

  wait_for_remote_health "$HOST" "http://127.0.0.1:18789/health" \
    "${GATEWAY_READY_ATTEMPTS:-12}" "${GATEWAY_READY_DELAY_SECONDS:-5}" "$SSH_USER"
  wait_for_remote_health "$HOST" "http://127.0.0.1:3001/health" \
    "${RUNTIME_READY_ATTEMPTS:-12}" "${RUNTIME_READY_DELAY_SECONDS:-5}" "$SSH_USER"
}

cleanup_on_error() {
  local exit_code=$?
  local failure_details=""
  local rollback_message=""

  if [[ "$ROLLBACK_IN_PROGRESS" == "1" ]]; then
    return
  fi

  echo ""
  echo "ERROR: Release apply failed (exit code: $exit_code)"

  if [[ -z "$INSTANCE_ID" ]]; then
    return
  fi

  failure_details="$(build_failure_details "$exit_code")"
  report_event "release_apply_failed" "$failure_details"

  if [[ "$ROLLBACK_READY" == "1" ]]; then
    echo "Attempting automatic rollback..."

    if rollback_release; then
      rollback_message="Release apply failed during ${CURRENT_STEP:-unknown}; automatic rollback succeeded."
      report_event "release_rollback_complete" "$(jq -nc --arg host "$HOST" '{host: $host}')"
      api_patch "$(jq -nc \
        --arg releaseJobStatus "failed" \
        --arg lastReleaseError "$rollback_message" \
        '{
          releaseJobStatus: $releaseJobStatus,
          lastReleaseError: $lastReleaseError
        }')" 2>/dev/null || true
      return
    fi

    rollback_message="Release apply failed during ${CURRENT_STEP:-unknown}; automatic rollback failed."
    report_event "release_rollback_failed" "$failure_details"
  else
    rollback_message="Release apply failed during ${CURRENT_STEP:-unknown}."
  fi

  api_patch "$(jq -nc \
    --arg status "failed" \
    --arg releaseJobStatus "failed" \
    --arg lastReleaseError "$rollback_message" \
    '{
      status: $status,
      releaseJobStatus: $releaseJobStatus,
      lastReleaseError: $lastReleaseError
    }')" 2>/dev/null || true
}

trap cleanup_on_error ERR

while [[ $# -gt 0 ]]; do
  case $1 in
    --instance-id) INSTANCE_ID="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    --platform-url) PLATFORM_URL="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: ./scripts/apply-release.sh --instance-id <uuid> [--host <ip>] [--platform-url <url>]"
  exit 1
fi

for var in PLATFORM_SERVICE_TOKEN CONFIG_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is not set."
    exit 1
  fi
done

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq"
  exit 1
fi

source "$SCRIPT_DIR/release-utils.sh"
CONFIG_REPO_DIR="$CONFIG_DIR"
trap cleanup_release_artifacts EXIT

CURRENT_STEP="fetch_instance"
INSTANCE="$(api_get)"

if [[ -z "$INSTANCE" ]]; then
  echo "Error: Could not fetch instance $INSTANCE_ID from platform API"
  exit 1
fi

STATUS="$(echo "$INSTANCE" | jq -r '.status')"
SLUG="$(echo "$INSTANCE" | jq -r '.slug')"
TEMPLATE_SLUG="$(echo "$INSTANCE" | jq -r '.templateSlug')"
SERVER_IP="$(echo "$INSTANCE" | jq -r '.serverIp // empty')"
RELEASE_ID="$(echo "$INSTANCE" | jq -r '.effectiveRelease.id // empty')"
RELEASE_VERSION="$(echo "$INSTANCE" | jq -r '.effectiveRelease.releaseVersion // empty')"
RELEASE_GATEWAY_IMAGE="$(echo "$INSTANCE" | jq -r '.effectiveRelease.gatewayImageRef // empty')"
RELEASE_WORKSPACE_IMAGE="$(echo "$INSTANCE" | jq -r '.effectiveRelease.workspaceSyncImageRef // empty')"
RELEASE_DOCKER_CONFIG_COMMIT="$(echo "$INSTANCE" | jq -r '.effectiveRelease.dockerConfigCommit // empty')"
PREVIOUS_RELEASE_ID="$(echo "$INSTANCE" | jq -r '.appliedReleaseId // empty')"

if [[ -z "$HOST" ]]; then
  HOST="$SERVER_IP"
fi

if [[ "$STATUS" != "active" ]]; then
  echo "Error: Instance status must be active to apply a release."
  exit 1
fi

if [[ -z "$HOST" ]]; then
  echo "Error: No instance host is available for $INSTANCE_ID"
  exit 1
fi

for var_name in RELEASE_ID RELEASE_VERSION RELEASE_GATEWAY_IMAGE RELEASE_WORKSPACE_IMAGE RELEASE_DOCKER_CONFIG_COMMIT; do
  if [[ -z "${!var_name:-}" ]]; then
    echo "Error: Effective release is not configured for this instance."
    exit 1
  fi
done

echo "═══════════════════════════════════════════════"
echo "  ClawStaffing Release Apply"
echo "═══════════════════════════════════════════════"
echo "  Instance: $SLUG"
echo "  Host:     $HOST"
echo "  Release:  $RELEASE_VERSION"
echo "═══════════════════════════════════════════════"
echo ""

CURRENT_STEP="mark_started"
api_patch "$(jq -nc \
  --arg releaseJobStatus "applying" \
  --arg lastReleaseError "" \
  '{
    releaseJobStatus: $releaseJobStatus,
    lastReleaseError: null
  }')"
report_event "release_apply_started" "$(jq -nc \
  --arg host "$HOST" \
  --arg releaseId "$RELEASE_ID" \
  --arg releaseVersion "$RELEASE_VERSION" \
  --arg previousReleaseId "$PREVIOUS_RELEASE_ID" \
  '{
    host: $host,
    releaseId: $releaseId,
    releaseVersion: $releaseVersion
  } + (if $previousReleaseId != "" then {previousReleaseId: $previousReleaseId} else {} end)')"

CURRENT_STEP="snapshot"
ROLLBACK_SNAPSHOT_DIR="/home/openclaw/release-snapshots/${INSTANCE_ID}-$(date +%Y%m%d_%H%M%S)"
ROLLBACK_GATEWAY_TAG="clawstaffing/rollback-openclaw-gateway:${INSTANCE_ID}"
ROLLBACK_WORKSPACE_TAG="clawstaffing/rollback-workspace-sync:${INSTANCE_ID}"

ssh -o StrictHostKeyChecking=accept-new "${SSH_USER}@${HOST}" \
  bash -s "$ROLLBACK_SNAPSHOT_DIR" "$ROLLBACK_GATEWAY_TAG" "$ROLLBACK_WORKSPACE_TAG" <<'REMOTE_SCRIPT'
set -euo pipefail

SNAPSHOT_DIR="$1"
ROLLBACK_GATEWAY_TAG="$2"
ROLLBACK_WORKSPACE_TAG="$3"
mkdir -p "$SNAPSHOT_DIR"

if [[ -f "$HOME/openclaw/.env" ]]; then
  cp "$HOME/openclaw/.env" "$SNAPSHOT_DIR/openclaw.env"
fi

if [[ -d "$HOME/.openclaw" ]]; then
  tar -czf "$SNAPSHOT_DIR/openclaw-home.tar.gz" -C "$HOME" ".openclaw"
fi

cd "$HOME/openclaw"

GATEWAY_CONTAINER="$(docker compose ps -q openclaw-gateway 2>/dev/null || true)"
if [[ -n "$GATEWAY_CONTAINER" ]]; then
  GATEWAY_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$GATEWAY_CONTAINER")"
  docker image tag "$GATEWAY_IMAGE_ID" "$ROLLBACK_GATEWAY_TAG"
fi

WORKSPACE_CONTAINER="$(docker compose ps -q workspace-sync 2>/dev/null || true)"
if [[ -n "$WORKSPACE_CONTAINER" ]]; then
  WORKSPACE_IMAGE_ID="$(docker inspect -f '{{.Image}}' "$WORKSPACE_CONTAINER")"
  docker image tag "$WORKSPACE_IMAGE_ID" "$ROLLBACK_WORKSPACE_TAG"
fi
REMOTE_SCRIPT

ROLLBACK_READY=1

CURRENT_STEP="checkout_config"
create_release_config_worktree "$CONFIG_REPO_DIR" "$RELEASE_DOCKER_CONFIG_COMMIT"
CONFIG_DIR="$RELEASE_CONFIG_DIR"

CURRENT_STEP="prepare_env"
TARGET_ENV_FILE="$(mktemp)"
scp -o StrictHostKeyChecking=accept-new \
  "${SSH_USER}@${HOST}:/home/openclaw/openclaw/.env" "$TARGET_ENV_FILE"
upsert_env_file_value "$TARGET_ENV_FILE" "OPENCLAW_GATEWAY_IMAGE" "$RELEASE_GATEWAY_IMAGE"
upsert_env_file_value "$TARGET_ENV_FILE" "WORKSPACE_SYNC_IMAGE" "$RELEASE_WORKSPACE_IMAGE"

CURRENT_STEP="push_config"
SKIP_RESTART=1 CONFIG_DIR="$RELEASE_CONFIG_DIR" ./scripts/push-config.sh "$HOST"

CURRENT_STEP="template_sync"
SKIP_SERVICE_RESTART=1 CONFIG_DIR="$RELEASE_CONFIG_DIR" \
  bash "$SCRIPT_DIR/sync-instance.sh" --instance-id "$INSTANCE_ID" --host "$HOST" --skip-events

CURRENT_STEP="push_env"
SKIP_RESTART=1 ENV_FILE="$TARGET_ENV_FILE" ./scripts/push-env.sh "$HOST"

CURRENT_STEP="deploy"
./deploy/deploy.sh "$HOST"

CURRENT_STEP="health_check"
wait_for_remote_health "$HOST" "http://127.0.0.1:18789/health" \
  "${GATEWAY_READY_ATTEMPTS:-12}" "${GATEWAY_READY_DELAY_SECONDS:-5}" "$SSH_USER"
wait_for_remote_health "$HOST" "http://127.0.0.1:3001/health" \
  "${RUNTIME_READY_ATTEMPTS:-12}" "${RUNTIME_READY_DELAY_SECONDS:-5}" "$SSH_USER"

CURRENT_STEP="finalize"
api_patch "$(jq -nc \
  --arg appliedReleaseId "$RELEASE_ID" \
  --arg releaseJobStatus "idle" \
  --arg lastReleaseAppliedAt "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  '{
    appliedReleaseId: $appliedReleaseId,
    releaseJobStatus: $releaseJobStatus,
    lastReleaseError: null,
    lastReleaseAppliedAt: $lastReleaseAppliedAt
  }')"

report_event "release_apply_complete" "$(jq -nc \
  --arg host "$HOST" \
  --arg releaseId "$RELEASE_ID" \
  --arg releaseVersion "$RELEASE_VERSION" \
  '{host: $host, releaseId: $releaseId, releaseVersion: $releaseVersion}')"

echo ""
echo "Release apply complete for $SLUG"
