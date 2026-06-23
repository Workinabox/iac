# ---------------------------------------------------------------------------
# Xen Orchestra connection
# ---------------------------------------------------------------------------
variable "xoa_url" {
  type        = string
  description = "Xen Orchestra websocket URL, e.g. wss://xoa.lan"
}

variable "xoa_token" {
  type        = string
  description = "Xen Orchestra API token"
  sensitive   = true
}

variable "xoa_insecure" {
  type        = string
  description = "Set to \"true\" to skip TLS verification (self-signed XOA cert)"
  default     = "false"
}

# ---------------------------------------------------------------------------
# Pool inventory (names must exist in your XO)
# ---------------------------------------------------------------------------
variable "template_name" {
  type        = string
  description = "Name of the Ubuntu 24.04 cloud-init template in XO"
}

variable "network_name" {
  type        = string
  description = "Name of the XO network to attach the VM to"
}

variable "storage_repository" {
  type        = string
  description = "Name of the storage repository (SR) for the VM disk"
}

# ---------------------------------------------------------------------------
# VM sizing
# ---------------------------------------------------------------------------
variable "hostname" {
  type        = string
  description = "VM name label and guest hostname"
  default     = "workinabox"
}

variable "vcpus" {
  type    = number
  default = 4
}

variable "memory_gb" {
  type    = number
  default = 8
}

variable "disk_gb" {
  type    = number
  default = 40
}

# ---------------------------------------------------------------------------
# Networking (static LAN IP)
# ---------------------------------------------------------------------------
variable "host_ip" {
  type        = string
  description = "Static LAN IP for the VM (outside the router DHCP pool)"
}

variable "cidr_prefix" {
  type        = number
  description = "LAN subnet prefix length, e.g. 24"
  default     = 24
}

variable "gateway" {
  type        = string
  description = "LAN default gateway"
}

variable "dns_servers" {
  type        = list(string)
  description = "DNS resolvers for the guest"
  default     = ["1.1.1.1", "9.9.9.9"]
}

variable "wait_for_ip_cidr" {
  type        = string
  description = "Terraform waits until the VM reports an IPv4 in this CIDR (guest-tools required). 0.0.0.0/0 = any."
  default     = "0.0.0.0/0"
}

variable "ssh_authorized_key" {
  type        = string
  description = "Public SSH key injected for the ubuntu user"
}

# ---------------------------------------------------------------------------
# Application config
# ---------------------------------------------------------------------------
variable "domain" {
  type        = string
  description = "FQDN served by nginx, e.g. workinabox.gos.dk"
}

variable "letsencrypt_email" {
  type        = string
  description = "Contact email for Let's Encrypt registration"
}

variable "announced_address" {
  type        = string
  description = "Address WebRTC/mediasoup announces to clients (public WAN IP if served via NAT, else host_ip)"
}

variable "backend_repo" {
  type        = string
  description = "GitHub owner/repo for the backend release"
  default     = "Workinabox/backend"
}

variable "frontend_repo" {
  type        = string
  description = "GitHub owner/repo for the frontend release"
  default     = "Workinabox/frontend"
}

variable "backend_version" {
  type        = string
  description = "Backend release to deploy: a tag like v0.2.0, or \"latest\". Bump + apply to update in place (no VM rebuild)."
  default     = "latest"
}

variable "frontend_version" {
  type        = string
  description = "Frontend release to deploy: a tag like v0.2.0, or \"latest\". Bump + apply to update in place (no VM rebuild)."
  default     = "latest"
}

variable "ssh_private_key_path" {
  type        = string
  description = "Path to the private key matching ssh_authorized_key, used for the in-place deploy over SSH"
  default     = "~/.ssh/id_rsa"
}

# ---------------------------------------------------------------------------
# Persistence (local PostgreSQL on the VM)
# ---------------------------------------------------------------------------
variable "db_provision_version" {
  type        = string
  description = "Bump this to re-run the PostgreSQL provisioning over SSH (install/config) without recreating the VM."
  default     = "v1"
}

variable "db_password" {
  type        = string
  description = "Password for the local 'wiab' Postgres role (localhost-only; not network-exposed)."
  default     = "wiab"
  sensitive   = true
}

# ---------------------------------------------------------------------------
# Local models (Llama LLM, Whisper STT). Files live in Azure blob storage and are
# fetched via azcopy into ${wiab_data_dir}/models by wiab-deploy — on first boot and
# on every in-place deploy. The backend only reads them. Changing the `models` map
# (add/remove an entry, change a filename, flip enabled) re-fetches on the next apply.
# Filenames are treated as IMMUTABLE: new weights ⇒ new filename (never overwrite a blob).
# ---------------------------------------------------------------------------
variable "wiab_data_dir" {
  type        = string
  description = "On-disk data directory holding model files under <dir>/models."
  default     = "/var/lib/wiab"
}

variable "wiab_models_url" {
  type        = string
  description = "Azure blob container URL WITH an embedded SAS token query string, e.g. https://<acct>.blob.core.windows.net/<container>?<SAS>. Read only by the deploy/fetch step, never by the app. Empty disables model fetching."
  default     = ""
  sensitive   = true
}

variable "models" {
  type = map(object({
    enabled = bool
    file    = string
  }))
  default     = {}
  description = <<-EOT
    Local models keyed by UPPERCASE role. Each key maps to the env vars the backend reads:
    role LLAMA -> WIAB_LLAMA_ENABLED + WIAB_LLAMA_MODEL_FILE. `file` is the immutable filename
    in the Azure container (and under <wiab_data_dir>/models). `enabled` toggles the model
    without removing its entry. Example:
      models = {
        LLAMA   = { enabled = true, file = "gemma-3-1b-it-Q4_K_M.gguf" }
        WHISPER = { enabled = true, file = "ggml-base.en.bin" }
      }
  EOT
}

# ---------------------------------------------------------------------------
# Identity / auth / email. Written to /etc/wiab/wiab.env (the systemd
# EnvironmentFile) over SSH and in-place updatable — edit and `terraform apply`,
# no VM rebuild. Google and OIDC turn on automatically once their credentials are
# non-empty (see locals in main.tf); leave blank to keep them off.
# ---------------------------------------------------------------------------
variable "auth_local_signup" {
  type        = bool
  description = "Enable local email+password signup (WIAB_AUTH_LOCAL_SIGNUP)."
  default     = true
}

variable "email_from" {
  type        = string
  description = "From address for transactional email — must be a domain verified in Resend."
  default     = "no-reply@workinabox.ai"
}

variable "resend_api_key" {
  type        = string
  description = "Resend API key (RESEND_API_KEY). Empty = email logs the link only, no send."
  default     = ""
  sensitive   = true
}

variable "google_client_id" {
  type        = string
  description = "Google OAuth client ID. Set together with google_client_secret to enable Google sign-in."
  default     = ""
}

variable "google_client_secret" {
  type        = string
  description = "Google OAuth client secret."
  default     = ""
  sensitive   = true
}

variable "oidc_issuer" {
  type        = string
  description = "Enterprise OIDC issuer URL (e.g. Microsoft Entra). Set with client id+secret to enable."
  default     = ""
}

variable "oidc_client_id" {
  type        = string
  description = "Enterprise OIDC client ID."
  default     = ""
}

variable "oidc_client_secret" {
  type        = string
  description = "Enterprise OIDC client secret."
  default     = ""
  sensitive   = true
}

variable "git_root" {
  type        = string
  description = "Durable directory for hosted git repos (WIAB_GIT_ROOT). Default keeps repos off /tmp."
  default     = "/var/lib/wiab/git"
}

# ---------------------------------------------------------------------------
# Firecracker smoke-test artifacts (bump as upstream rotates them)
# ---------------------------------------------------------------------------
variable "fc_test_kernel_url" {
  type        = string
  description = "URL to an uncompressed vmlinux for the Firecracker boot smoke test"
  default     = "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.10/x86_64/vmlinux-5.10.223"
}

variable "fc_test_rootfs_url" {
  type        = string
  description = "URL to an ext4 rootfs for the Firecracker boot smoke test"
  default     = "https://s3.amazonaws.com/spec.ccfc.min/firecracker-ci/v1.10/x86_64/ubuntu-22.04.ext4"
}
