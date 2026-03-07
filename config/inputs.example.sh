#!/bin/bash
# ============================================
# ClawStaffing - Input Configuration Example
# ============================================
# Copy this file to inputs.sh and fill in your values:
#   cp config/inputs.example.sh config/inputs.sh
#
# Source before running Terraform or Make targets:
#   source config/inputs.sh
#
# Security model:
#   - Customer access: HTTPS via Caddy (auto-TLS at CUSTOMER_SLUG.clawstaffing.com)
#   - Admin access: Tailscale SSH (key-only, no root, fail2ban)
#   - Gateway: localhost-only, proxied by Caddy
#   - DNS: automated via Cloudflare
#
# NEVER commit inputs.sh to version control

# ============================================
# Hetzner Cloud API Token
# ============================================
# Generate at: https://console.hetzner.cloud/ -> Projects -> API Tokens
export HCLOUD_TOKEN="CHANGE_ME_your-hcloud-token-here"
export TF_VAR_hcloud_token="$HCLOUD_TOKEN"

# ============================================
# Cloudflare (DNS automation)
# ============================================
# Create an API token at: https://dash.cloudflare.com/profile/api-tokens
# Required permissions: Zone > DNS > Edit (scoped to your domain's zone)
# Zone ID: found on your domain's Overview page in Cloudflare dashboard
export TF_VAR_cloudflare_api_token="CHANGE_ME_your-cloudflare-api-token"
export TF_VAR_cloudflare_zone_id="CHANGE_ME_your-cloudflare-zone-id"

# ============================================
# SSH Configuration
# ============================================
# Fingerprint of your existing Hetzner SSH key
# List yours: curl -s -H "Authorization: Bearer $HCLOUD_TOKEN" https://api.hetzner.cloud/v1/ssh_keys | jq '.ssh_keys[] | {name, fingerprint}'
export TF_VAR_ssh_key_fingerprint="CHANGE_ME_your-ssh-key-fingerprint"

# SSH is key-only (password disabled). Keep 0.0.0.0/0 for bootstrap,
# or restrict to your IP + Tailscale CGNAT range (100.64.0.0/10).
export TF_VAR_ssh_allowed_cidrs='["0.0.0.0/0"]'

# ============================================
# Config Directory (path to openclaw-docker-config repo)
# ============================================
export CONFIG_DIR="/path/to/your/openclaw-docker-config"

# ============================================
# OPTIONAL: Platform Provisioner Auth
# ============================================
# Needed when running scripts/provision.sh manually against the web platform.
# Matches the PROVISIONER_PLATFORM_TOKEN configured on clawstaffing-web.
# export PLATFORM_URL="https://www.clawstaffing.com"
# export PLATFORM_SERVICE_TOKEN="CHANGE_ME_provisioner-platform-token"

# ============================================
# GitHub Container Registry
# ============================================
# For pulling private Docker images during bootstrap and deploy
# Create a PAT at: https://github.com/settings/tokens with read:packages scope
export GHCR_USERNAME="your-github-username"
export GHCR_TOKEN="CHANGE_ME_your-github-pat-with-read-packages-scope"

# ============================================
# OPTIONAL: Claude Setup Token (for Claude Max/Pro subscription)
# ============================================
# Use your Claude subscription instead of paying for API credits.
# Generate with: claude setup-token
# Then run: make setup-auth
export CLAUDE_SETUP_TOKEN=""

# ============================================
# Tailscale VPN (admin access — enabled by default)
# ============================================
# Generate a pre-auth key at: https://login.tailscale.com/admin/settings/keys
# Use a reusable, ephemeral key tagged with your ACL tag.
export TF_VAR_enable_tailscale=true
export TF_VAR_tailscale_auth_key=""
export TF_VAR_tailscale_hostname="openclaw-prod"

# ============================================
# Customer Configuration
# ============================================
# Subdomain slug — Terraform creates: slug.clawstaffing.com → VPS IP
# Caddy auto-provisions Let's Encrypt certs on first HTTPS request.
export TF_VAR_customer_slug="your-customer-slug"

# ============================================
# SERVER CONNECTION (optional override)
# ============================================
# When using Tailscale (ssh_allowed_cidrs='[]'), set this to the
# Tailscale hostname so make commands connect via VPN.
# Leave empty to auto-detect from terraform output.
# export SERVER_IP=""

# ============================================
# Server Configuration (Optional Overrides)
# ============================================
# export TF_VAR_server_type="cx23"
# export TF_VAR_server_location="nbg1"

# ============================================
# OPTIONAL: Hetzner Object Storage (remote state)
# ============================================
# For Terraform remote state storage (local state works fine for getting started)
# Create bucket at: https://console.hetzner.cloud/ -> Object Storage
# export AWS_ACCESS_KEY_ID="your-s3-access-key"
# export AWS_SECRET_ACCESS_KEY="your-s3-secret-key"
