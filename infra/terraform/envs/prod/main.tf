# ============================================
# Production Environment - Terraform Configuration
# ============================================
# This configuration creates a ClawStaffing customer instance:
#   - Hetzner VPS with security hardening
#   - Cloudflare DNS record (customer_slug.domain → VPS IP)
#   - Caddy auto-TLS via Let's Encrypt
#   - Tailscale for admin SSH access

terraform {
  required_version = ">= 1.5"

  required_providers {
    hcloud = {
      source  = "hetznercloud/hcloud"
      version = "~> 1.45"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }

  # Remote state backend (optional) - credentials via AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY env vars
  #
  # Uncomment to use Hetzner Object Storage for remote state:
  # 1. Create a bucket at https://console.hetzner.cloud/ -> Object Storage
  # 2. Get endpoint URL (e.g., https://nbg1.your-objectstorage.com)
  # 3. Create access keys
  # 4. Set environment variables:
  #    export AWS_ACCESS_KEY_ID="your-access-key"
  #    export AWS_SECRET_ACCESS_KEY="your-secret-key"
  # 5. Uncomment the backend block below
  #
  # For first-time setup, local state (default) is fine. Migrate to remote state later.
  #
  # backend "s3" {
  #   endpoints = {
  #     s3 = "https://REGION.your-objectstorage.com"  # Replace with your endpoint
  #   }
  #   bucket                      = "openclaw-tfstate"
  #   key                         = "prod/terraform.tfstate"
  #   region                      = "main"
  #   skip_credentials_validation = true
  #   skip_metadata_api_check     = true
  #   skip_region_validation      = true
  #   skip_requesting_account_id  = true
  #   skip_s3_checksum            = true
  #   use_path_style              = true
  # }
}

# ============================================
# Locals
# ============================================

locals {
  customer_hostname = "${var.customer_slug}.${var.domain}"
}

# ============================================
# Providers
# ============================================

provider "hcloud" {
  token = var.hcloud_token
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

# ============================================
# VPS Module
# ============================================

module "vps" {
  source = "../../modules/hetzner-vps"

  project_name        = var.project_name
  environment         = "prod"
  customer_slug       = var.customer_slug
  ssh_key_fingerprint = var.ssh_key_fingerprint
  ssh_allowed_cidrs   = var.ssh_allowed_cidrs
  server_type         = var.server_type
  server_location     = var.server_location
  app_user            = var.app_user
  app_directory       = var.app_directory

  # Security configuration
  enable_tailscale = var.enable_tailscale

  cloud_init_user_data = templatefile("${path.module}/../../../cloud-init/user-data.yml.tpl", {
    app_user           = var.app_user
    app_directory      = var.app_directory
    enable_tailscale   = var.enable_tailscale
    tailscale_auth_key = var.tailscale_auth_key
    tailscale_hostname = var.tailscale_hostname
  })
}

# ============================================
# Cloudflare DNS Record
# ============================================
# Creates: vinny.clawstaffing.com → VPS IPv4
# Proxied is OFF so Caddy handles TLS directly (Let's Encrypt).

resource "cloudflare_record" "customer_a" {
  zone_id = var.cloudflare_zone_id
  name    = var.customer_slug
  type    = "A"
  content = module.vps.server_ipv4
  proxied = false
  ttl     = 300
  comment = "ClawStaffing instance for ${var.customer_slug}"
}

# ============================================
# Outputs
# ============================================

output "server_ip" {
  description = "Public IPv4 address of the OpenClaw server"
  value       = module.vps.server_ipv4
}

output "server_ipv6" {
  description = "Public IPv6 address of the OpenClaw server"
  value       = module.vps.server_ipv6
}

output "server_id" {
  description = "Hetzner Cloud server ID"
  value       = module.vps.server_id
}

output "server_status" {
  description = "Current status of the server"
  value       = module.vps.server_status
}

output "ssh_command" {
  description = "SSH command to connect as the application user"
  value       = module.vps.ssh_command
}

output "ssh_command_root" {
  description = "SSH command to connect as root (disabled on hardened instances)"
  value       = "Root login disabled. Use: ${module.vps.ssh_command} then sudo"
}

output "ssh_key_id" {
  description = "Hetzner Cloud SSH key ID"
  value       = module.vps.ssh_key_id
}

output "firewall_id" {
  description = "Hetzner Cloud firewall ID"
  value       = module.vps.firewall_id
}

output "tailscale_enabled" {
  description = "Whether Tailscale VPN is enabled"
  value       = module.vps.tailscale_enabled
}

output "customer_hostname" {
  description = "Customer-facing FQDN for HTTPS access"
  value       = local.customer_hostname
}

output "dashboard_url" {
  description = "URL to access the OpenClaw dashboard"
  value       = "https://${local.customer_hostname}"
}

output "dns_record" {
  description = "Cloudflare DNS record created"
  value       = "${local.customer_hostname} → ${module.vps.server_ipv4}"
}
