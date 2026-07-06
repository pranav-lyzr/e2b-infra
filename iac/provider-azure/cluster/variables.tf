variable "subscription_id" {
  type        = string
  description = "Azure subscription ID."
}

variable "location" {
  type    = string
  default = "eastus"
}

variable "prefix" {
  type    = string
  default = "e2b"
}

variable "resource_group_name" {
  type    = string
  default = "e2b-cluster"
}

variable "tags" {
  type = map(string)
  default = {
    project = "e2b"
    mode    = "cluster-multi-node"
  }
}

# --- Access ---
variable "admin_source_cidr" {
  type        = string
  description = "CIDR allowed to reach management ports (SSH, DB). Lock to your egress."
  default     = "0.0.0.0/0"
}

variable "ssh_public_key" {
  type        = string
  description = "SSH public key for the compute + ClickHouse VMs."
}

# --- PostgreSQL (Azure Database for PostgreSQL Flexible Server) ---
variable "pg_admin_username" {
  type    = string
  default = "e2b"
}

# NOTE: pg_admin_password is generated (random_password.postgres) for the
# self-hosted Postgres; this var is kept for compatibility but unused.
variable "pg_admin_password" {
  type        = string
  sensitive   = true
  default     = ""
  description = "Unused (self-hosted Postgres uses a generated password)."
}

# --- Redis: self-hosted on the data VM (no Azure Cache for Redis) ---
# (E2B's Redis client has no AUTH support on the single-node path, and Azure
# Cache for Redis mandates an access key — so Redis runs as a no-auth in-VNet
# container on the ClickHouse/data VM instead. No variables needed.)

# --- Storage (object store for templates/build cache) ---
variable "storage_account_name" {
  type        = string
  description = "Globally-unique storage account name (3-24 lowercase alphanumerics)."
}

# --- Container registry ---
variable "acr_name" {
  type        = string
  description = "Globally-unique ACR name (5-50 alphanumerics)."
}

variable "acr_sku" {
  type    = string
  default = "Standard"
}

# --- Data VM (self-hosted Postgres + Redis + ClickHouse) ---
variable "clickhouse_vm_size" {
  type    = string
  default = "Standard_D4s_v3"
}

variable "clickhouse_admin_username" {
  type    = string
  default = "e2b"
}

# --- Compute tier ---
variable "control_vm_size" {
  type        = string
  description = "Control node (Nomad server + API + client-proxy). No nested virt needed."
  default     = "Standard_D2s_v3"
}

variable "orchestrator_vm_size" {
  type        = string
  description = "Orchestrator VMSS instance size. MUST support nested virtualization."
  default     = "Standard_D4s_v3"
}

variable "orchestrator_instance_count" {
  type        = number
  description = "Number of orchestrator nodes in the VMSS."
  default     = 2
}

variable "nomad_version" {
  type    = string
  default = "1.9.3"
}

variable "acr_repository_name" {
  type        = string
  description = "Repository within ACR that holds template images."
  default     = "e2b"
}

variable "repo_url" {
  type    = string
  default = "https://github.com/pranav-lyzr/e2b-infra.git"
}

variable "repo_ref" {
  type    = string
  default = "main"
}
