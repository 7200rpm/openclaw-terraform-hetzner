# OpenClaw Terraform Hetzner

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)
[![Terraform](https://img.shields.io/badge/Terraform-1.5+-purple.svg)](https://www.terraform.io/)

Terraform modules for deploying [OpenClaw](https://github.com/openclaw/openclaw) on Hetzner Cloud. Includes VPS provisioning, Cloudflare DNS automation, Caddy reverse proxy with auto-TLS, SSH hardening, and deployment tooling.

## Overview

This repository provides infrastructure-as-code for deploying OpenClaw—an open-source AI coding assistant—on a Hetzner Cloud VPS. The setup includes:

- **Customer HTTPS access** via Caddy reverse proxy with automatic Let's Encrypt TLS
- **Cloudflare DNS automation** — `terraform apply` creates both the VPS and DNS record
- **SSH hardening** — key-only auth, no root login, fail2ban, rate limiting
- **Tailscale VPN** for admin SSH access (enabled by default)
- Modular Terraform structure with optional remote S3 state backend
- Automated server provisioning via cloud-init
- Dual-layer firewall (UFW + Hetzner Cloud Firewall)
- Deployment scripts for application lifecycle management
- Backup and restore functionality

For information about OpenClaw itself, see the [OpenClaw documentation](https://docs.openclaw.ai/).

## Prerequisites

1. **Terraform** >= 1.5 ([Installation Guide](https://developer.hashicorp.com/terraform/install))
2. **Hetzner Cloud Account** with API token ([Console](https://console.hetzner.cloud/))
3. **Cloudflare Account** with API token for DNS automation ([Dashboard](https://dash.cloudflare.com/profile/api-tokens))
4. **SSH Key** at `~/.ssh/id_rsa.pub`
5. **Docker configuration repo**: [openclaw-docker-config](https://github.com/andreesg/openclaw-docker-config)
6. **Hetzner Object Storage** for Terraform state (optional but recommended)

## Quick Start

### 1. Clone Repository

```bash
git clone https://github.com/andreesg/openclaw-terraform-hetzner.git
cd openclaw-terraform-hetzner
```

### 2. Configure Secrets

```bash
cp config/inputs.example.sh config/inputs.sh
vim config/inputs.sh  # Add your Hetzner API token and configuration
```

Required variables in `config/inputs.sh`:
- `HCLOUD_TOKEN` — Hetzner Cloud API token
- `TF_VAR_ssh_key_fingerprint` — SSH key fingerprint from Hetzner
- `TF_VAR_cloudflare_api_token` — Cloudflare API token (Zone > DNS > Edit permission)
- `TF_VAR_cloudflare_zone_id` — Cloudflare zone ID for your domain
- `TF_VAR_customer_slug` — Subdomain slug (e.g. `vinny` creates `vinny.clawstaffing.com`)
- `CONFIG_DIR` — Path to your openclaw-docker-config repository
- `GHCR_USERNAME` / `GHCR_TOKEN` — GitHub Container Registry credentials

Optional:
- `TF_VAR_tailscale_auth_key` — Pre-auth key for automatic Tailscale enrollment
- `TF_VAR_tailscale_hostname` — Tailscale device name (default: `openclaw-prod`)
- `SERVER_IP` — Override SSH target (set to Tailscale hostname for VPN-only access)

### 3. Deploy Infrastructure

```bash
source config/inputs.sh
make init
make plan
make apply
```

### 4. Bootstrap OpenClaw

```bash
make bootstrap
make deploy
```

### 5. Verify Deployment

```bash
make status
make logs
make dashboard  # Opens https://your-slug.clawstaffing.com
```

## Architecture

```
                        ┌──────────────┐
                        │  Cloudflare  │
                        │  DNS Record  │
                        │  (auto)      │
                        └──────┬───────┘
                               │
  Customer                     │  slug.clawstaffing.com
  ─────────────────────────────┼──────────────────────────────
  Admin                        │
                               v
┌─────────────────┐   ┌──────────────────────────────────┐
│   Your Laptop   │   │      Hetzner Cloud VPS           │
│                 │   │                                  │
│  ┌───────────┐  │   │  ┌────────┐     ┌─────────────┐ │
│  │ Terraform │──┼──>│  │ Caddy  │────>│  OpenClaw    │ │
│  └───────────┘  │   │  │ :443   │     │  Gateway     │ │
│                 │   │  │ (TLS)  │     │  :18789      │ │
│  ┌───────────┐  │   │  └────────┘     │  (localhost) │ │
│  │  Config   │──┼──>│                 └─────────────┘ │
│  │   Repo    │  │   │                                  │
│  └───────────┘  │   │  Firewall: SSH + HTTP/S only     │
│                 │   │  SSH: key-only, no root, fail2ban│
│  ┌───────────┐  │   │  Tailscale: admin VPN access     │
│  │ Tailscale │──┼──>│                                  │
│  │   (SSH)   │  │   └──────────────────────────────────┘
│  └───────────┘  │
└─────────────────┘
```

### Access Model

| Plane | Who | How | Auth |
|-------|-----|-----|------|
| **Customer** | End users | `https://slug.clawstaffing.com` | Gateway token |
| **Admin** | Operators | `ssh openclaw@<IP>` or Tailscale SSH | SSH key (no root, no password) |

### Components

| Component | Purpose | Location |
|-----------|---------|----------|
| **infra/terraform/** | VPS + DNS + Firewall | This repo |
| **infra/cloud-init/** | Server hardening on first boot | This repo |
| **deploy/** | Deployment automation | This repo |
| **docker/** | Container configuration + Caddyfile | [openclaw-docker-config](https://github.com/andreesg/openclaw-docker-config) |
| **config/** | OpenClaw configuration | [openclaw-docker-config](https://github.com/andreesg/openclaw-docker-config) |

## Usage

### Makefile Targets

**Infrastructure:**
```bash
make init       # Initialize Terraform
make plan       # Show infrastructure changes
make apply      # Apply infrastructure changes
make destroy    # Destroy all infrastructure
make output     # Show Terraform outputs
```

**Deployment:**
```bash
make bootstrap  # Initial OpenClaw setup
make deploy     # Pull latest image and restart
make status     # Check deployment status
make logs       # Stream container logs
```

**Operations:**
```bash
make ssh        # SSH to VPS as openclaw user
make dashboard  # Open customer HTTPS dashboard in browser
make tunnel     # Create SSH tunnel to gateway (fallback)
make backup-now # Trigger backup immediately
make restore    # Restore from backup (BACKUP=filename)
```

**Tailscale:**
```bash
make tailscale-status   # Check Tailscale status (uses public IP — run before closing port 22)
make tailscale-ip       # Get Tailscale IP (uses public IP — run before closing port 22)
make tailscale-up       # Manually authenticate Tailscale
```

**Configuration:**
```bash
make push-env    # Push environment variables
make push-config # Push OpenClaw configuration
make setup-auth  # Configure Claude subscription auth
```

## Configuration

### Server Sizing

Default: CX23 (2 vCPU, 4GB RAM)

To change server type, add to `config/inputs.sh`:
```bash
export TF_VAR_server_type="cx32"  # 4 vCPU, 8GB RAM
```

See [Hetzner server types](https://www.hetzner.com/cloud#pricing).

### Firewall Rules

The VPS has a dual-layer firewall: Hetzner Cloud Firewall (network level) and UFW (OS level). Both enforce the same rules:

| Port | Protocol | Purpose |
|------|----------|---------|
| 22 | TCP | SSH (key-only, no root, fail2ban) |
| 80 | TCP | HTTP (Let's Encrypt ACME challenges) |
| 443 | TCP | HTTPS (Caddy reverse proxy) |
| 41641 | UDP | Tailscale WireGuard (when enabled) |

SSH is open to `0.0.0.0/0` by default. Restrict before production:

**Option A — Restrict to your IP:**
```bash
# In config/inputs.sh
export TF_VAR_ssh_allowed_cidrs='["203.0.113.50/32"]'
source config/inputs.sh && make plan && make apply
```

**Option B — Tailscale VPN (recommended):**

Tailscale creates a private WireGuard mesh so SSH is reachable only from devices on your tailnet.

1. Get an auth key at [login.tailscale.com/admin/settings/keys](https://login.tailscale.com/admin/settings/keys) — use **reusable + pre-authorized** keys, not ephemeral.

2. Add to `config/inputs.sh`:
   ```bash
   export TF_VAR_tailscale_auth_key="tskey-auth-xxxxxxxxxxxxx"
   export TF_VAR_tailscale_hostname="openclaw-vinny"
   ```

3. Deploy and verify:
   ```bash
   source config/inputs.sh && make plan && make apply
   make tailscale-status          # confirm node is connected
   ssh openclaw@<tailscale-ip>  # confirm Tailscale SSH works
   ```

4. Close public SSH:
   ```bash
   export TF_VAR_ssh_allowed_cidrs='[]'
   export SERVER_IP="openclaw-vinny"   # Tailscale MagicDNS hostname
   source config/inputs.sh && make plan && make apply
   ```

> **Note:** Tailscale is installed by default (`enable_tailscale=true`). Without an auth key, it installs but doesn't auto-connect — run `make tailscale-up` to authenticate manually.

> **Recovery:** If Tailscale fails, use [Hetzner web console](https://console.hetzner.cloud/) for emergency access.

### Remote State Backend

The S3 backend configuration is commented out by default in `infra/terraform/envs/prod/main.tf`. To enable:

1. Create Hetzner Object Storage bucket
2. Set credentials in `config/inputs.sh`:
   ```bash
   export AWS_ACCESS_KEY_ID="your-access-key"
   export AWS_SECRET_ACCESS_KEY="your-secret-key"
   ```
3. Uncomment backend block in `main.tf` and update endpoint URL
4. Run `terraform init -migrate-state`

### Switching AI Providers

OpenClaw supports multiple AI providers. This setup defaults to Anthropic Claude, but you can switch to other providers by modifying the configuration in [openclaw-docker-config](https://github.com/andreesg/openclaw-docker-config).

**Supported providers:**
- Anthropic Claude (Opus, Sonnet, Haiku)
- OpenAI (GPT-4, GPT-3.5, o1)
- DeepSeek (V3, R1)
- Local models (via Ollama or LM Studio)

**To switch providers:**

1. Update `openclaw.json` in the config repo:
   ```json
   {
     "agents": {
       "defaults": {
         "model": {
           "primary": "openai/gpt-4"
         }
       }
     },
     "auth": {
       "profiles": {
         "openai:main": {
           "provider": "openai",
           "mode": "token"
         }
       }
     }
   }
   ```

2. Update `secrets/openclaw.env`:
   ```bash
   OPENAI_API_KEY=sk-...
   ```

3. Redeploy:
   ```bash
   make push-config deploy
   ```

See [OpenClaw provider documentation](https://docs.openclaw.ai/providers) for detailed configuration.

## Common Workflows

### Initial Deployment

```bash
# 1. Configure secrets
cp config/inputs.example.sh config/inputs.sh
vim config/inputs.sh

# 2. Deploy infrastructure
source config/inputs.sh
make init plan apply

# 3. Bootstrap application
make bootstrap

# 4. Deploy OpenClaw
make deploy

# 5. Verify
make status logs
```

### Updating OpenClaw

```bash
# Pull latest image and restart
make deploy

# Check logs
make logs
```

### Updating Configuration

```bash
# Edit openclaw.json in config repo
vim ~/path/to/openclaw-docker-config/config/openclaw.json

# Push and restart
make push-config deploy
```

### Backup and Restore

Backups run daily at 02:00 UTC via systemd timer.

```bash
# Manual backup
make backup-now

# List backups
make ssh
ls -lh ~/backups/

# Restore from backup
make restore BACKUP=openclaw-backup-2026-02-08.tar.gz
```

### Accessing the Dashboard

The OpenClaw dashboard is accessible via HTTPS at your customer hostname:

```bash
make dashboard  # Opens https://slug.clawstaffing.com
```

Caddy automatically provisions a Let's Encrypt TLS certificate on first request. The gateway asks for your **Gateway Token** — paste your `OPENCLAW_GATEWAY_TOKEN` value (from `secrets/openclaw.env`) to authenticate.

**How it works:** Caddy listens on ports 80/443, handles TLS termination, and reverse-proxies to the OpenClaw gateway on `localhost:18789`. The gateway never receives direct internet traffic.

**Fallback — SSH tunnel** (if DNS/TLS isn't set up yet):
```bash
make tunnel  # Creates tunnel: localhost:18789 -> VPS:18789
# Then open http://localhost:18789
```

**Tailscale Serve** (alternative for private access):
```bash
make tailscale-serve  # Exposes gateway on your tailnet
# Dashboard at https://openclaw-hostname.tailnet.ts.net
```

## Troubleshooting

### Terraform Init Fails

**Cause:** S3 backend credentials not set

**Solution:**
```bash
source config/inputs.sh
make init
```

Or use local state by commenting out the backend block in `infra/terraform/envs/prod/main.tf`.

### Container Won't Start

**Check logs:**
```bash
make logs
make ssh
docker compose -f ~/openclaw/docker-compose.yml ps
```

**Common causes:**

- Missing environment variables in `.env`
- Invalid OpenClaw configuration
- API key issues

**Fix:**
```bash
make push-env    # Re-push environment variables
make push-config # Re-push OpenClaw config
make deploy      # Restart
```

### Can't SSH to VPS

**Common causes after VPS recreation:**
```bash
# Host key changed — clear old key
ssh-keygen -R <VPS_IP>

# Then retry
ssh openclaw@<VPS_IP>
```

**Firewall blocking SSH:**
```bash
grep TF_VAR_ssh_allowed_cidrs config/inputs.sh
```

If `ssh_allowed_cidrs='[]'` (Tailscale-only mode), connect via Tailscale instead:
```bash
ssh openclaw@<tailscale-hostname>
```

**Root login disabled (by design):**
Root login is disabled on all hardened instances. Use `make ssh` (connects as `openclaw`), then `sudo` if needed.

Emergency access: [Hetzner web console](https://console.hetzner.cloud/) → server → Console.

### Permission Denied on ~/.openclaw

If you see `Permission denied` when creating directories under `~/.openclaw` (e.g. during `make setup-auth`), Docker likely took ownership of the directory via the volume mount. This can happen if you ran `make deploy` before bootstrap finished, or if you're re-running bootstrap after a previous deploy.

**Fix:**
```bash
ssh openclaw@VPS_IP "sudo chown -R openclaw:openclaw ~/.openclaw"
```

Then re-run `make bootstrap` or `make setup-auth`.

### Bootstrap Fails

**Verify prerequisites:**
```bash
# Check CONFIG_DIR is set and exists
echo $CONFIG_DIR
ls $CONFIG_DIR/docker/docker-compose.yml

# Verify GHCR credentials
docker login ghcr.io -u YOUR_GITHUB_USERNAME
```

### SSH Host Key Changed

**Cause:** Destroyed and re-provisioned the VPS — new server has a different
host key at the same public IP.

**Error:** `WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!`

**Fix:**

```bash
ssh-keygen -R <old_vps_ip>
# Then retry — SSH will prompt you to accept the new key.
```

### API Billing Error

**Anthropic API key issues:**

If using API key (not subscription):
```bash
# Check key is set
make ssh
grep ANTHROPIC_API_KEY ~/openclaw/.env

# Verify key has credits at console.anthropic.com
```

If using Claude subscription:
```bash
# Re-run setup-auth
make setup-auth

# Verify auth profile exists
make ssh
cat ~/.openclaw/agents/main/agent/auth-profiles.json
```

## Security

See [SECURITY.md](SECURITY.md) for the full security policy and threat model.

### What's Hardened by Default

Every VPS created by this repo gets the following security baseline via cloud-init:

| Layer | Configuration |
|-------|---------------|
| **SSH** | Key-only auth, root login disabled, `MaxAuthTries 3`, empty passwords disabled |
| **fail2ban** | SSH jail: 5 retries → 1 hour ban (configurable) |
| **UFW Firewall** | Deny all inbound except SSH, HTTP, HTTPS, Tailscale |
| **Hetzner Firewall** | Same rules enforced at the network level |
| **Tailscale** | Installed by default with `--ssh` flag for VPN-based admin access |
| **Directory perms** | App directories `chmod 700` (owner-only) |
| **Docker** | Log rotation (10MB, 3 files), gateway bound to localhost only |
| **TLS** | Caddy auto-provisions Let's Encrypt certificates |

### Secrets Management

- Never commit `config/inputs.sh` or `secrets/openclaw.env`
- Use environment variables for all credentials
- Rotate API tokens periodically
- Review `.gitignore` before committing

## Project Structure

```
.
├── infra/
│   ├── terraform/
│   │   ├── globals/          # Shared backend/provider config
│   │   ├── envs/prod/        # Production: VPS + DNS + firewall
│   │   └── modules/
│   │       └── hetzner-vps/  # VPS module (server + firewall)
│   └── cloud-init/
│       └── user-data.yml.tpl # Server hardening + Docker + Tailscale
├── deploy/                   # Deployment scripts
│   ├── bootstrap.sh          # Initial setup (docker-compose, Caddyfile, env, backups)
│   ├── deploy.sh             # Pull image + restart containers
│   ├── backup.sh             # Backup script
│   └── restore.sh            # Restore from backup
├── scripts/                  # Utility scripts
│   ├── push-env.sh           # Push secrets to VPS
│   ├── push-config.sh        # Push config to VPS
│   └── setup-auth.sh         # Setup subscription auth
├── config/
│   └── inputs.example.sh     # Configuration template (tokens, slugs, Cloudflare)
└── secrets/
    └── openclaw.env.example  # Secrets template (API keys, gateway token)
```

## Infrastructure Costs

See [Hetzner Cloud pricing](https://www.hetzner.com/cloud#pricing) for current rates. This setup uses a small shared VPS (default: CX23) plus minimal object storage for Terraform state.

> **Note:** Prices exclude Anthropic/OpenAI API costs.

## Contributing

Contributions are welcome! Please see [CONTRIBUTING.md](CONTRIBUTING.md) for guidelines.

**Ways to contribute:**
- Report bugs via [GitHub Issues](https://github.com/andreesg/openclaw-terraform-hetzner/issues)
- Submit feature requests
- Improve documentation
- Submit pull requests
- Share your deployment experiences

## Related Projects

- **[OpenClaw](https://github.com/openclaw/openclaw)** — The AI coding assistant this infrastructure deploys
- **[openclaw-docker-config](https://github.com/andreesg/openclaw-docker-config)** — Docker and OpenClaw configuration (companion repo)

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## Support

- **Issues:** [GitHub Issues](https://github.com/andreesg/openclaw-terraform-hetzner/issues)
- **Discussions:** [GitHub Discussions](https://github.com/andreesg/openclaw-terraform-hetzner/discussions)
- **OpenClaw Docs:** [docs.openclaw.ai](https://docs.openclaw.ai/)
