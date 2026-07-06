variable "subscription_id" {
  type        = string
  description = "Azure subscription ID to deploy into."
}

variable "location" {
  type        = string
  description = "Azure region. Must offer a nested-virtualization-capable Dv-series size."
  default     = "eastus"
}

variable "prefix" {
  type        = string
  description = "Name prefix for all created resources."
  default     = "e2b"
}

variable "resource_group_name" {
  type        = string
  description = "Resource group to create for this deployment."
  default     = "e2b-single-box"
}

# ---------------------------------------------------------------------------
# Compute
# ---------------------------------------------------------------------------

variable "vm_size" {
  type        = string
  description = <<-EOT
    VM SKU. MUST support nested virtualization (KVM / /dev/kvm) for Firecracker.
    Verified families: Dv5/Dsv5, Dv6/Dsv6, Ev5, Fsv2. The user validated Dv6.
      - Standard_D16s_v6  = 16 vCPU / 64 GB  (minimum for ~20 sessions)
      - Standard_D32s_v6  = 32 vCPU / 128 GB (comfortable headroom + template builds)
  EOT
  default     = "Standard_D16s_v6"
}

variable "admin_username" {
  type        = string
  description = "Linux admin username for SSH."
  default     = "e2b"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key material (contents of your id_ed25519.pub / id_rsa.pub)."
}

variable "os_disk_size_gb" {
  type        = number
  description = "OS disk size (GB). Holds the repo, Go build cache, and Docker images."
  default     = 100
}

variable "data_disk_size_gb" {
  type        = number
  description = <<-EOT
    Premium SSD data disk (GB), mounted at /opt/e2b/data. Holds local template
    storage, build cache, and sandbox/snapshot caches. Scale with template count.
  EOT
  default     = 256
}

# ---------------------------------------------------------------------------
# Capacity sizing — drives huge pages, NBD pool, and snapshot cache
# ---------------------------------------------------------------------------

variable "sessions" {
  type        = number
  description = "Target number of concurrent sandbox sessions on this box."
  default     = 20
}

variable "per_session_vcpu" {
  type        = number
  description = "Planned vCPU per sandbox (used only for sizing docs/oversubscription math)."
  default     = 2
}

variable "per_session_ram_mb" {
  type        = number
  description = <<-EOT
    Planned RAM per sandbox in MB. Huge pages are pre-reserved to cover
    sessions * this value, so do not over-set it (reserved pages are unusable
    by the OS/Postgres/build). E2B base default is ~512; 1024 leaves headroom.
  EOT
  default     = 1024
}

# ---------------------------------------------------------------------------
# Networking / access
# ---------------------------------------------------------------------------

variable "admin_source_cidr" {
  type        = string
  description = <<-EOT
    CIDR allowed to reach SSH (22) and the E2B API (3000) + sandbox proxy (3002).
    Set to your office/VPN egress. Avoid 0.0.0.0/0 in production — the local-dev
    tokens are well-known and must be rotated before any wider exposure.
  EOT
  default     = "0.0.0.0/0"
}

# ---------------------------------------------------------------------------
# Source repo to build on the box
# ---------------------------------------------------------------------------

variable "repo_url" {
  type        = string
  description = "Git URL of the e2b-infra fork to clone and build on the VM."
  default     = "https://github.com/pranav-lyzr/e2b-infra.git"
}

variable "repo_ref" {
  type        = string
  description = "Git ref (branch/tag/sha) to check out."
  default     = "main"
}

variable "tags" {
  type        = map(string)
  description = "Tags applied to all resources."
  default = {
    project = "e2b"
    mode    = "single-box-local-providers"
  }
}
