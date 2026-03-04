# ============================================
# Production Environment Variables
# ============================================

# ============================================
# Required: API Tokens
# ============================================

variable "hcloud_token" {
  description = "Hetzner Cloud API token"
  type        = string
  sensitive   = true
}

variable "cloudflare_api_token" {
  description = "Cloudflare API token (needs DNS:Edit permission for the zone)"
  type        = string
  sensitive   = true
}

# ============================================
# Required: SSH Configuration
# ============================================

variable "ssh_key_fingerprint" {
  description = "Fingerprint of an existing Hetzner SSH key to use (avoids recreating shared keys)"
  type        = string
}

variable "ssh_allowed_cidrs" {
  description = "CIDR blocks allowed to SSH (e.g., ['1.2.3.4/32'])"
  type        = list(string)
  default     = []
}

# ============================================
# Project Configuration
# ============================================

variable "project_name" {
  description = "Name of the project"
  type        = string
  default     = "openclaw"
}

# ============================================
# Server Configuration
# ============================================

variable "server_type" {
  description = "Hetzner server type"
  type        = string
  default     = "cx23"
}

variable "server_location" {
  description = "Hetzner datacenter location"
  type        = string
  default     = "nbg1"
}

# ============================================
# Application Configuration
# ============================================

variable "app_user" {
  description = "Non-root user to create on the server"
  type        = string
  default     = "openclaw"
}

variable "app_directory" {
  description = "Application directory path"
  type        = string
  default     = "/home/openclaw/.openclaw"
}

# ============================================
# Security Configuration
# ============================================

variable "enable_tailscale" {
  description = "Install and configure Tailscale VPN for admin access"
  type        = bool
  default     = true
}

variable "tailscale_auth_key" {
  description = "Tailscale pre-auth key for automatic registration (required when enable_tailscale=true)"
  type        = string
  default     = ""
  sensitive   = true
}

variable "tailscale_hostname" {
  description = "Tailscale hostname for this instance (e.g., openclaw-vinny)"
  type        = string
  default     = "openclaw-prod"
}

# ============================================
# Customer Configuration (DNS + HTTPS)
# ============================================

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID for the customer domain (find in Cloudflare dashboard → Overview)"
  type        = string
}

variable "domain" {
  description = "Base domain for customer instances"
  type        = string
  default     = "clawstaffing.com"
}

variable "customer_slug" {
  description = "Customer subdomain slug (e.g., 'vinny' → vinny.clawstaffing.com)"
  type        = string
}
