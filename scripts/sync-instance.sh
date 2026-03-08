#!/bin/bash
set -euo pipefail

INSTANCE_ID=""
HOST=""
PLATFORM_URL="${PLATFORM_URL:-https://www.clawstaffing.com}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_SERVICE_TOKEN="${PLATFORM_SERVICE_TOKEN:-${PROVISIONER_PLATFORM_TOKEN:-}}"
CURRENT_STEP=""
SKIP_EVENTS=0

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

while [[ $# -gt 0 ]]; do
  case $1 in
    --instance-id) INSTANCE_ID="$2"; shift 2;;
    --host) HOST="$2"; shift 2;;
    --platform-url) PLATFORM_URL="$2"; shift 2;;
    --skip-events) SKIP_EVENTS=1; shift 1;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: ./scripts/sync-instance.sh --instance-id <uuid> [--host <ip>] [--platform-url <url>]"
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

api_get() {
  curl -sf "$PLATFORM_URL/api/instances/$INSTANCE_ID" \
    -H "Authorization: Bearer $PLATFORM_SERVICE_TOKEN" \
    -H "X-Claw-Service: provisioner"
}

api_get_secret_response() {
  local kind="$1"
  curl -s -w "\n%{http_code}" \
    "$PLATFORM_URL/api/instances/$INSTANCE_ID/integrations/$kind/secret" \
    -H "Authorization: Bearer $PLATFORM_SERVICE_TOKEN" \
    -H "X-Claw-Service: provisioner"
}

report_event() {
  if [[ "$SKIP_EVENTS" == "1" ]]; then
    return 0
  fi
  local event_type="$1"
  local details="${2:-}"
  curl -sf -X POST "$PLATFORM_URL/api/instances/$INSTANCE_ID/events" \
    -H "Authorization: Bearer $PLATFORM_SERVICE_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Claw-Service: provisioner" \
    -d "{\"eventType\": \"$event_type\", \"details\": $details}" > /dev/null 2>&1 || true
}

cleanup_on_error() {
  local exit_code=$?

  if [[ -n "$INSTANCE_ID" ]]; then
    report_event "runtime_sync_failed" "$(build_failure_details "$exit_code")"
  fi
}
trap cleanup_on_error ERR

CURRENT_STEP="fetch_instance"
INSTANCE="$(api_get)"
if [[ -z "$INSTANCE" ]]; then
  echo "Error: Could not fetch instance $INSTANCE_ID from platform API"
  exit 1
fi

SLUG="$(echo "$INSTANCE" | jq -r '.slug')"
TEMPLATE_SLUG="$(echo "$INSTANCE" | jq -r '.templateSlug')"
CUSTOMER_NAME="$(echo "$INSTANCE" | jq -r '.customerName // empty')"
CUSTOMER_ROLE="$(echo "$INSTANCE" | jq -r '.customerRole // empty')"
CUSTOMER_COMPANY="$(echo "$INSTANCE" | jq -r '.customerCompany // empty')"
CUSTOMER_TIMEZONE="$(echo "$INSTANCE" | jq -r '.customerTimezone // "America/Denver"')"
RENDERED_USER="$(echo "$INSTANCE" | jq -r '.renderedConfig.userMarkdown // empty')"
RENDERED_SOUL_OVERRIDE="$(echo "$INSTANCE" | jq -r '.renderedConfig.soulOverrideMarkdown // empty')"
RENDERED_MEMORY="$(echo "$INSTANCE" | jq -r '.renderedConfig.memorySeedMarkdown // empty')"

if [[ -z "$HOST" ]]; then
  HOST="$(echo "$INSTANCE" | jq -r '.serverIp // empty')"
fi

if [[ -z "$HOST" ]]; then
  echo "Error: No instance host is available for $INSTANCE_ID"
  exit 1
fi

if [[ -z "$TEMPLATE_SLUG" || "$TEMPLATE_SLUG" == "null" ]]; then
  echo "Error: Instance template is missing."
  exit 1
fi

if [[ -z "$RENDERED_USER" || -z "$RENDERED_SOUL_OVERRIDE" || -z "$RENDERED_MEMORY" ]]; then
  echo "Error: Rendered onboarding config is incomplete. Submit onboarding before syncing."
  exit 1
fi

TEMPLATE_DIR="$CONFIG_DIR/templates/$TEMPLATE_SLUG"
if [[ ! -d "$TEMPLATE_DIR/scripts" ]]; then
  echo "Error: Template scripts not found at $TEMPLATE_DIR/scripts"
  exit 1
fi

CURRENT_STEP="write_rendered_files"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

USER_FILE="$TMP_DIR/USER.md"
SOUL_OVERRIDE_FILE="$TMP_DIR/SOUL-OVERRIDE.md"
MEMORY_FILE="$TMP_DIR/MEMORY.md"
GWS_CREDENTIALS_FILE=""

printf "%s\n" "$RENDERED_USER" > "$USER_FILE"
printf "%s\n" "$RENDERED_SOUL_OVERRIDE" > "$SOUL_OVERRIDE_FILE"
printf "%s\n" "$RENDERED_MEMORY" > "$MEMORY_FILE"

GWS_RESPONSE="$(api_get_secret_response google_workspace)"
GWS_STATUS="$(printf '%s\n' "$GWS_RESPONSE" | tail -n1)"
GWS_BODY="$(printf '%s\n' "$GWS_RESPONSE" | sed '$d')"

if [[ "$GWS_STATUS" == "200" ]]; then
  GWS_CREDENTIALS_FILE="$TMP_DIR/gws-credentials.json"
  echo "$GWS_BODY" | jq -r '.credentialsJson // empty' > "$GWS_CREDENTIALS_FILE"
fi

SYNC_DETAILS="$(jq -nc --arg host "$HOST" --arg slug "$SLUG" '{host: $host, slug: $slug}')"
report_event "runtime_sync_started" "$SYNC_DETAILS"

CURRENT_STEP="deploy_template"
cd "$TEMPLATE_DIR/scripts"

SYNC_ARGS=(
  --instance-id "$INSTANCE_ID"
  --host "$HOST"
  --name "$CUSTOMER_NAME"
  --role "$CUSTOMER_ROLE"
  --company "$CUSTOMER_COMPANY"
  --timezone "$CUSTOMER_TIMEZONE"
  --user-file "$USER_FILE"
  --memory-file "$MEMORY_FILE"
  --soul-override-file "$SOUL_OVERRIDE_FILE"
)

if [[ -n "$GWS_CREDENTIALS_FILE" ]]; then
  SYNC_ARGS+=(--gws-credentials-file "$GWS_CREDENTIALS_FILE")
fi

bash deploy-customer.sh "${SYNC_ARGS[@]}"

cd "$REPO_DIR"
CURRENT_STEP="complete"
report_event "runtime_sync_complete" "$SYNC_DETAILS"
