#!/bin/bash
set -euo pipefail

# ============================================
# ClawStaffing — Instance Provisioning Script
# ============================================
# Provisions a customer OpenClaw instance end-to-end.
# Reads instance config from the platform API, runs Terraform,
# bootstraps the VPS, and reports status back.
#
# Usage:
#   source config/inputs.sh
#   ./scripts/provision.sh --instance-id <uuid>
#
# Requires:
#   - PLATFORM_SERVICE_TOKEN and PLATFORM_URL in environment
#   - All standard inputs.sh variables (HCLOUD_TOKEN, etc.)
#   - CONFIG_DIR pointing to openclaw-docker-config repo
#   - jq installed

INSTANCE_ID=""
PLATFORM_URL="${PLATFORM_URL:-https://www.clawstaffing.com}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLATFORM_SERVICE_TOKEN="${PLATFORM_SERVICE_TOKEN:-${PROVISIONER_PLATFORM_TOKEN:-}}"
CURRENT_STEP=""

build_failure_details() {
  local exit_code="$1"

  if command -v jq &>/dev/null; then
    jq -nc \
      --arg step "${CURRENT_STEP:-unknown}" \
      --arg serverIp "${SERVER_IP:-}" \
      --argjson exitCode "$exit_code" \
      '{
        step: $step,
        exitCode: $exitCode
      } + (if $serverIp != "" then {serverIp: $serverIp} else {} end)'
  elif [[ -n "${SERVER_IP:-}" ]]; then
    printf '{"step":"%s","exitCode":%s,"serverIp":"%s"}' \
      "${CURRENT_STEP:-unknown}" "$exit_code" "$SERVER_IP"
  else
    printf '{"step":"%s","exitCode":%s}' \
      "${CURRENT_STEP:-unknown}" "$exit_code"
  fi
}

wait_for_ssh() {
  local attempts="${SSH_READY_ATTEMPTS:-12}"
  local delay_seconds="${SSH_READY_DELAY_SECONDS:-10}"
  local attempt

  for attempt in $(seq 1 "$attempts"); do
    if ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 \
      "openclaw@$SERVER_IP" "echo 'SSH OK'" >/dev/null 2>&1; then
      echo "[OK] SSH access confirmed"
      return 0
    fi

    if [[ "$attempt" -lt "$attempts" ]]; then
      echo "SSH not ready yet (attempt ${attempt}/${attempts}); retrying in ${delay_seconds}s..."
      sleep "$delay_seconds"
    fi
  done

  echo "Error: SSH did not become ready on $SERVER_IP after ${attempts} attempts."
  return 1
}

# ─── Error handler ──────────────────────────────────────────────
cleanup_on_error() {
  local exit_code=$?
  local failure_details=""
  echo ""
  echo "ERROR: Provisioning failed (exit code: $exit_code)"
  if [[ -n "$INSTANCE_ID" ]]; then
    failure_details="$(build_failure_details "$exit_code")"
    if [[ -n "$CURRENT_STEP" ]]; then
      report_event "${CURRENT_STEP}_failed" "$failure_details" 2>/dev/null || true
    fi
    api_patch '{"status": "failed"}' 2>/dev/null || true
    report_event "provisioning_failed" "$failure_details" 2>/dev/null || true
  fi
}
trap cleanup_on_error ERR

# ─── Parse arguments ─────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case $1 in
    --instance-id) INSTANCE_ID="$2"; shift 2;;
    --platform-url) PLATFORM_URL="$2"; shift 2;;
    *) echo "Unknown option: $1"; exit 1;;
  esac
done

if [[ -z "$INSTANCE_ID" ]]; then
  echo "Usage: ./scripts/provision.sh --instance-id <uuid>"
  echo ""
  echo "Required environment variables:"
  echo "  PLATFORM_SERVICE_TOKEN  - Provisioner service token for the platform"
  echo "                           (or PROVISIONER_PLATFORM_TOKEN)"
  echo "  HCLOUD_TOKEN      - Hetzner Cloud API token"
  echo "  CONFIG_DIR        - Path to openclaw-docker-config repo"
  echo ""
  echo "Run 'source config/inputs.sh' first."
  exit 1
fi

# ─── Validate environment ────────────────────────────────────────
for var in PLATFORM_SERVICE_TOKEN HCLOUD_TOKEN CONFIG_DIR; do
  if [[ -z "${!var:-}" ]]; then
    echo "Error: $var is not set. Run 'source config/inputs.sh' first."
    exit 1
  fi
done

if ! command -v jq &>/dev/null; then
  echo "Error: jq is required. Install with: brew install jq"
  exit 1
fi

# ─── Helper: API calls ───────────────────────────────────────────
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

api_put_credentials() {
  curl -sf -X PUT "$PLATFORM_URL/api/instances/$INSTANCE_ID/credentials" \
    -H "Authorization: Bearer $PLATFORM_SERVICE_TOKEN" \
    -H "Content-Type: application/json" \
    -H "X-Claw-Service: provisioner" \
    -d "$1"
}

api_get_credentials() {
  curl -s -w "\n%{http_code}" "$PLATFORM_URL/api/instances/$INSTANCE_ID/credentials" \
    -H "Authorization: Bearer $PLATFORM_SERVICE_TOKEN" \
    -H "X-Claw-Service: provisioner"
}

load_existing_credentials() {
  local response=""
  local status=""
  local body=""

  response="$(api_get_credentials)"
  status="$(printf '%s\n' "$response" | tail -n1)"
  body="$(printf '%s\n' "$response" | sed '$d')"

  if [[ "$status" == "200" ]]; then
    EXISTING_BASIC_AUTH_USER="$(echo "$body" | jq -r '.basicAuthUser // empty')"
    EXISTING_BASIC_AUTH_PASSWORD="$(echo "$body" | jq -r '.basicAuthPassword // empty')"
    EXISTING_GATEWAY_TOKEN="$(echo "$body" | jq -r '.gatewayToken // empty')"

    if [[ -n "$EXISTING_BASIC_AUTH_USER" && -n "$EXISTING_BASIC_AUTH_PASSWORD" && -n "$EXISTING_GATEWAY_TOKEN" ]]; then
      return 0
    fi

    echo "Warning: Platform returned incomplete credentials; generating new access credentials."
    return 1
  fi

  if [[ "$status" != "404" ]]; then
    echo "Warning: Could not load existing credentials from platform (HTTP $status); generating new access credentials."
  fi

  return 1
}

# ─── Step 1: Fetch instance details ──────────────────────────────
echo "═══════════════════════════════════════════════"
echo "  ClawStaffing Instance Provisioner"
echo "═══════════════════════════════════════════════"
echo ""
echo "Fetching instance details..."

INSTANCE=$(api_get)
if [[ -z "$INSTANCE" ]]; then
  echo "Error: Could not fetch instance $INSTANCE_ID from platform API"
  exit 1
fi

SLUG=$(echo "$INSTANCE" | jq -r '.slug')
TEMPLATE_SLUG=$(echo "$INSTANCE" | jq -r '.templateSlug')
CUSTOMER_NAME=$(echo "$INSTANCE" | jq -r '.customerName // empty')
CUSTOMER_ROLE=$(echo "$INSTANCE" | jq -r '.customerRole // empty')
CUSTOMER_COMPANY=$(echo "$INSTANCE" | jq -r '.customerCompany // empty')
CUSTOMER_TIMEZONE=$(echo "$INSTANCE" | jq -r '.customerTimezone // "America/Denver"')
STATUS=$(echo "$INSTANCE" | jq -r '.status')
SSH_KNOWN_HOSTS_FILE="${SSH_KNOWN_HOSTS_FILE:-/data/ssh/known_hosts}"

echo "  Instance: $SLUG ($CUSTOMER_NAME)"
echo "  Template: $TEMPLATE_SLUG"
echo "  Status:   $STATUS"
echo ""

if [[ "$STATUS" != "approved" ]]; then
  echo "Error: Instance status is '$STATUS', expected 'approved'"
  echo "Approve the instance in the admin panel first."
  exit 1
fi

# ─── Step 2: Generate credentials ────────────────────────────────
echo "Resolving access credentials..."
if load_existing_credentials; then
  GATEWAY_TOKEN="$EXISTING_GATEWAY_TOKEN"
  BASIC_AUTH_USER="$EXISTING_BASIC_AUTH_USER"
  BASIC_AUTH_PASSWORD="$EXISTING_BASIC_AUTH_PASSWORD"
  echo "Reusing existing credentials from the platform secret store..."
else
  echo "Generating new credentials..."
  GATEWAY_TOKEN=$(openssl rand -hex 32)
  BASIC_AUTH_USER="$SLUG"
  BASIC_AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/' | head -c 20)
fi

echo "  Gateway token:    ${GATEWAY_TOKEN:0:8}..."
echo "  Basic auth user:  $BASIC_AUTH_USER"
echo "  Basic auth pass:  ${BASIC_AUTH_PASSWORD:0:4}..."
echo ""

# ─── Step 3: Update status to provisioning ───────────────────────
echo "Updating status to 'provisioning'..."
api_patch '{"status": "provisioning"}'

# ─── Step 4: Terraform ───────────────────────────────────────────
echo ""
echo "──── Terraform ────────────────────────────────"
CURRENT_STEP="terraform"
report_event "terraform_started" '""'

cd "$REPO_DIR/infra/terraform/envs/prod"

# Use Terraform workspace for customer isolation
terraform workspace select -or-create "$SLUG" 2>/dev/null

# Set customer-specific variables
export TF_VAR_customer_slug="$SLUG"
export TF_VAR_tailscale_hostname="openclaw-$SLUG"

echo "Workspace: $(terraform workspace show)"
echo "Running terraform apply..."
terraform apply -auto-approve

SERVER_IP=$(terraform output -raw server_ip)
SERVER_ID=$(terraform output -raw server_id 2>/dev/null || echo "")

echo ""
echo "  Server IP: $SERVER_IP"
echo "  Server ID: $SERVER_ID"

report_event "terraform_complete" "{\"serverIp\": \"$SERVER_IP\", \"serverId\": \"$SERVER_ID\"}"

# Return to repo root
cd "$REPO_DIR"

# ─── Step 5: Wait for cloud-init ─────────────────────────────────
echo ""
echo "──── Waiting for cloud-init ───────────────────"
echo "Waiting 90 seconds for server setup..."
sleep 90

# Clear old host key
ssh-keygen -R "$SERVER_IP" -f "$SSH_KNOWN_HOSTS_FILE" >/dev/null 2>&1 || true
ssh-keygen -R "$SERVER_IP" >/dev/null 2>&1 || true

# Verify SSH access
echo "Testing SSH access..."
CURRENT_STEP="ssh_check"
wait_for_ssh

# ─── Step 6: Generate customer .env ──────────────────────────────
echo ""
echo "──── Generating secrets ───────────────────────"
CURRENT_STEP="generate_secrets"

echo "Staging access credentials in platform..."
api_put_credentials "{
  \"basicAuthUser\": \"$BASIC_AUTH_USER\",
  \"basicAuthPassword\": \"$BASIC_AUTH_PASSWORD\",
  \"gatewayToken\": \"$GATEWAY_TOKEN\"
}"

# Generate basic auth hash using htpasswd (works without Docker-in-Docker)
# Falls back to caddy if htpasswd is not available
if command -v htpasswd &>/dev/null; then
  BASIC_AUTH_HASH=$(htpasswd -nbBC 10 "" "$BASIC_AUTH_PASSWORD" | tr -d ':\n' | sed 's/$2y/$2a/')
else
  BASIC_AUTH_HASH=$(docker run --rm caddy:2-alpine caddy hash-password --plaintext "$BASIC_AUTH_PASSWORD" 2>/dev/null)
fi

cat > secrets/openclaw.env << EOF
# Generated by provision.sh for: $SLUG
# Instance ID: $INSTANCE_ID
# Generated at: $(date -u +%Y-%m-%dT%H:%M:%SZ)

ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY:-}
MINIMAX_API_KEY=${MINIMAX_API_KEY:-}
TELEGRAM_BOT_TOKEN=${TELEGRAM_BOT_TOKEN:-}
OPENCLAW_GATEWAY_TOKEN=$GATEWAY_TOKEN
OPENCLAW_GATEWAY_PORT=18789
OPENCLAW_GATEWAY_BIND=0.0.0.0
OPENCLAW_CONFIG_DIR=/home/openclaw/.openclaw
OPENCLAW_WORKSPACE_DIR=/home/openclaw/.openclaw/workspace
CUSTOMER_HOSTNAME=${SLUG}.clawstaffing.com
BASIC_AUTH_USER=$BASIC_AUTH_USER
BASIC_AUTH_HASH='$BASIC_AUTH_HASH'
GHCR_USERNAME=${GHCR_USERNAME:-}
GH_TOKEN=${GH_TOKEN:-}
BRAVE_SEARCH_API_KEY=${BRAVE_SEARCH_API_KEY:-}
EOF

echo "Secrets written to secrets/openclaw.env"

# ─── Step 7: Bootstrap ───────────────────────────────────────────
echo ""
echo "──── Bootstrap ────────────────────────────────"
CURRENT_STEP="bootstrap"
report_event "bootstrap_started" '""'

export SERVER_IP
BOOTSTRAP_SSH_PROMPT=0 ./deploy/bootstrap.sh 2>&1

report_event "bootstrap_complete" '""'

# ─── Step 8: Deploy customer template ────────────────────────────
echo ""
echo "──── Template deployment ──────────────────────"
CURRENT_STEP="template_deploy"

TEMPLATE_DIR="$CONFIG_DIR/templates/$TEMPLATE_SLUG"
if [[ -d "$TEMPLATE_DIR/scripts" ]]; then
  report_event "template_deploy_started" '""'
  echo "Deploying $TEMPLATE_SLUG template..."
  cd "$TEMPLATE_DIR/scripts"
  bash deploy-customer.sh \
    --host "$SERVER_IP" \
    --name "$CUSTOMER_NAME" \
    --role "$CUSTOMER_ROLE" \
    --company "$CUSTOMER_COMPANY" \
    --timezone "$CUSTOMER_TIMEZONE"
  cd "$REPO_DIR"
  report_event "template_deploy_complete" '""'
else
  echo "No template scripts found at $TEMPLATE_DIR/scripts, skipping..."
fi

# ─── Step 9: Deploy containers ───────────────────────────────────
echo ""
echo "──── Deploy containers ────────────────────────"
CURRENT_STEP="deploy"
report_event "deploy_started" '""'

./deploy/deploy.sh 2>&1

report_event "deploy_complete" '""'

# ─── Step 10: Update platform ────────────────────────────────────
echo ""
echo "──── Updating platform ────────────────────────"
CURRENT_STEP="finalize"

api_put_credentials "{
  \"basicAuthUser\": \"$BASIC_AUTH_USER\",
  \"basicAuthPassword\": \"$BASIC_AUTH_PASSWORD\",
  \"gatewayToken\": \"$GATEWAY_TOKEN\"
}"

api_patch "{
  \"status\": \"active\",
  \"serverIp\": \"$SERVER_IP\",
  \"hetznerServerId\": \"$SERVER_ID\",
  \"provisionedAt\": \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"
}"

CURRENT_STEP=""

# ─── Done ─────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════"
echo "  Instance provisioned successfully!"
echo "═══════════════════════════════════════════════"
echo ""
echo "  URL:            https://${SLUG}.clawstaffing.com"
echo "  Server IP:      $SERVER_IP"
echo "  Basic Auth:     $BASIC_AUTH_USER / $BASIC_AUTH_PASSWORD"
echo "  Gateway Token:  ${GATEWAY_TOKEN:0:16}..."
echo ""
echo "  The customer can find all credentials in their portal."
echo ""
