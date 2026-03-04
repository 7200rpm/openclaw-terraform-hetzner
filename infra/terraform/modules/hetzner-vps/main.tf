# Hetzner VPS Module
# ============================================
# Creates an OpenClaw VPS with:
# - SSH key authentication (key-only, no password)
# - Firewall (SSH + HTTP/S + Tailscale inbound)
# - Cloud-init provisioning with security hardening
# - Docker pre-installed
# - Caddy reverse proxy for auto-TLS

terraform {
  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
  }
}

# ============================================
# SSH Key (lookup existing key by fingerprint)
# ============================================

data "hcloud_ssh_key" "main" {
  fingerprint = var.ssh_key_fingerprint
}

# ============================================
# Firewall
# ============================================

locals {
  name_suffix = var.customer_slug != "" ? "${var.project_name}-${var.customer_slug}" : "${var.project_name}-${var.environment}"
}

resource "hcloud_firewall" "main" {
  name = "${local.name_suffix}-firewall"

  # Allow SSH from specified CIDRs (for bootstrap/admin via public IP)
  dynamic "rule" {
    for_each = var.ssh_allowed_cidrs
    content {
      direction  = "in"
      protocol   = "tcp"
      port       = "22"
      source_ips = [rule.value]
    }
  }

  # Allow HTTP (for ACME/Let's Encrypt challenges)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "80"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Allow HTTPS (Caddy reverse proxy → OpenClaw dashboard)
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }

  # Allow Tailscale UDP (if enabled — default: on)
  dynamic "rule" {
    for_each = var.enable_tailscale ? [1] : []
    content {
      direction  = "in"
      protocol   = "udp"
      port       = "41641"
      source_ips = ["0.0.0.0/0", "::/0"]
    }
  }

  # Allow all outbound traffic
  rule {
    direction       = "out"
    protocol        = "tcp"
    port            = "1-65535"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "udp"
    port            = "1-65535"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }

  rule {
    direction       = "out"
    protocol        = "icmp"
    destination_ips = ["0.0.0.0/0", "::/0"]
  }
}

# ============================================
# Server
# ============================================

resource "hcloud_server" "main" {
  name        = local.name_suffix
  server_type = var.server_type
  image       = var.server_image
  location    = var.server_location
  ssh_keys    = [data.hcloud_ssh_key.main.id]

  user_data = var.cloud_init_user_data

  labels = {
    project     = var.project_name
    environment = var.environment
    managed_by  = "terraform"
  }

  public_net {
    ipv4_enabled = true
    ipv6_enabled = true
  }

  lifecycle {
    ignore_changes = [
      user_data,
      ssh_keys,
    ]
  }
}

# ============================================
# Firewall Attachment
# ============================================

resource "hcloud_firewall_attachment" "main" {
  firewall_id = hcloud_firewall.main.id
  server_ids  = [hcloud_server.main.id]
}
