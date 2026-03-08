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

# ─── Error handler ──────────────────────────────────────────────
cleanup_on_error() {
  local exit_code=$?
  echo ""
  echo "ERROR: Provisioning failed (exit code: $exit_code)"
  if [[ -n "$INSTANCE_ID" ]]; then
    api_patch '{"status": "failed"}' 2>/dev/null || true
    report_event "provisioning_failed" "{\"exitCode\": $exit_code}" 2>/dev/null || true
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
echo "Generating credentials..."
GATEWAY_TOKEN=$(openssl rand -hex 32)
BASIC_AUTH_USER="$SLUG"
BASIC_AUTH_PASSWORD=$(openssl rand -base64 16 | tr -d '=+/' | head -c 20)

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
ssh -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 "openclaw@$SERVER_IP" "echo 'SSH OK'" || {
  echo "Warning: SSH test failed, continuing anyway..."
}

# ─── Step 6: Generate customer .env ──────────────────────────────
echo ""
echo "──── Generating secrets ───────────────────────"

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
report_event "bootstrap_started" '""'

export SERVER_IP
echo "n" | ./deploy/bootstrap.sh 2>&1 || true

report_event "bootstrap_complete" '""'

# ─── Step 8: Deploy customer template ────────────────────────────
echo ""
echo "──── Template deployment ──────────────────────"

TEMPLATE_DIR="$CONFIG_DIR/templates/$TEMPLATE_SLUG"
if [[ -d "$TEMPLATE_DIR/scripts" ]]; then
  echo "Deploying $TEMPLATE_SLUG template..."
  cd "$TEMPLATE_DIR/scripts"
  bash deploy-customer.sh \
    --host "$SERVER_IP" \
    --name "$CUSTOMER_NAME" \
    --role "$CUSTOMER_ROLE" \
    --company "$CUSTOMER_COMPANY" \
    --timezone "$CUSTOMER_TIMEZONE" || {
    echo "Warning: Template deployment had issues, continuing..."
  }
  cd "$REPO_DIR"
else
  echo "No template scripts found at $TEMPLATE_DIR/scripts, skipping..."
fi

# ─── Step 9: Deploy containers ───────────────────────────────────
echo ""
echo "──── Deploy containers ────────────────────────"
report_event "deploy_started" '""'

./deploy/deploy.sh 2>&1 || true

report_event "deploy_complete" '""'

# ─── Step 10: Update platform ────────────────────────────────────
echo ""
echo "──── Updating platform ────────────────────────"

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
