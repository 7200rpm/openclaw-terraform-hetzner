# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added
- **Caddy Reverse Proxy**: Customer HTTPS access via Caddy with automatic Let's Encrypt TLS
  - Bootstrap copies `Caddyfile` to VPS alongside `docker-compose.yml`
  - Firewall opens ports 80 (ACME challenges) and 443 (HTTPS) at both Hetzner and UFW layers
  - New `make dashboard` target opens `https://slug.clawstaffing.com` in browser
- **Cloudflare DNS Automation**: `terraform apply` creates DNS records automatically
  - New Cloudflare Terraform provider (~> 4.0)
  - `cloudflare_record` resource creates `A` record: `customer_slug.domain` → VPS IP
  - New variables: `cloudflare_api_token`, `cloudflare_zone_id`, `domain`, `customer_slug`
  - New outputs: `customer_hostname`, `dashboard_url`, `dns_record`
- **SSH Hardening**: Drop-in config deployed via cloud-init (`/etc/ssh/sshd_config.d/99-clawstaffing-hardening.conf`)
  - Password authentication disabled
  - Root login disabled (`PermitRootLogin no`)
  - Max auth tries reduced to 3
  - Client alive interval (300s) with max 2 missed keepalives
  - X11 forwarding disabled
- **fail2ban**: SSH jail with 5 retries → 1 hour ban, deployed via cloud-init
- **Tailscale VPN Integration**: Optional Tailscale VPN support for secure private networking
  - New Terraform variables: `enable_tailscale`, `tailscale_auth_key`, `tailscale_hostname`
  - Automatic Tailscale installation and authentication via cloud-init
  - Tailscale SSH enabled by default (`--ssh` flag)
  - Dynamic hostname via `tailscale_hostname` variable
  - UFW firewall rule for Tailscale UDP port (41641)
  - New Makefile targets: `tailscale-status`, `tailscale-ip`, `tailscale-up`

### Changed
- Tailscale enabled by default (`enable_tailscale` default changed from `false` to `true`)
- App directory permissions tightened from 755 to 700
- `make ssh-root` now prints warning that root login is disabled
- Makefile header updated to document security model (customer HTTPS + admin SSH)
- Cloud-init template updated with hardening, fail2ban, Caddy ports, and Tailscale SSH

### Fixed
- YAML parsing bug in cloud-init: unquoted string containing `: ` (colon-space) in `runcmd` was interpreted as a YAML mapping, causing the entire `runcmd` section to fail silently. This prevented user creation while SSH hardening (from `write_files`) still took effect, locking out all access.

### Security
- Two-plane access model: customers via HTTPS (Caddy), admins via SSH (Tailscale)
- SSH attack surface reduced: no root, no passwords, fail2ban rate limiting
- Gateway never directly exposed to internet (Caddy handles TLS termination)
- Reduced attack surface: SSH and gateway can be accessed via private Tailscale VPN
- End-to-end WireGuard encryption for all Tailscale traffic
- Tailscale auth keys stored as sensitive Terraform variables

### Documentation
- README rewritten with new architecture diagram showing Caddy/Cloudflare/Tailscale
- Security section updated with hardening baseline table
- SECURITY.md updated with fail2ban, SSH hardening, and TLS details
- CHANGELOG updated with all changes since v1.0.0

## [1.0.0] - 2025-02-08

### Added
- Initial release of OpenClaw Terraform infrastructure for Hetzner Cloud
- Modular Terraform structure (globals, environments, modules)
- hetzner-vps module for VPS provisioning with cloud-init
- Deployment automation via Makefile
- Bootstrap script for initial OpenClaw setup
- Deploy script for pulling and restarting containers
- Backup and restore functionality
- Status monitoring and log streaming
- SSH tunneling support for gateway access
- Claude subscription auth setup via setup-token
- Environment variable management (inputs.sh, openclaw.env)
- Comprehensive documentation (README, CONTRIBUTING, SECURITY)
- GitHub Actions CI/CD (Terraform validation, ShellCheck)
- Issue and PR templates

### Security
- Firewall configuration (SSH-only by default)
- UFW setup via cloud-init
- Secrets externalized to environment variables
- .gitignore for sensitive files

[Unreleased]: https://github.com/andreesg/openclaw-terraform-hetzner/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/andreesg/openclaw-terraform-hetzner/releases/tag/v1.0.0
