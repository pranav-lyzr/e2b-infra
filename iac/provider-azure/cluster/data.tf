########################################
# Object storage — templates + build cache (backs storage_azure.go)
########################################
resource "azurerm_storage_account" "this" {
  name                     = var.storage_account_name
  resource_group_name      = azurerm_resource_group.this.name
  location                 = azurerm_resource_group.this.location
  account_tier             = "Standard"
  account_replication_type = "LRS"
  min_tls_version          = "TLS1_2"
  tags                     = var.tags
}

resource "azurerm_storage_container" "templates" {
  name                  = "templates"
  storage_account_name  = azurerm_storage_account.this.name
  container_access_type = "private"
}

resource "azurerm_storage_container" "build_cache" {
  name                  = "build-cache"
  storage_account_name  = azurerm_storage_account.this.name
  container_access_type = "private"
}

########################################
# Container registry — ACR (backs registry_azure.go)
########################################
resource "azurerm_container_registry" "this" {
  name                = var.acr_name
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.acr_sku
  # Admin user enabled so nodes authenticate with basic creds (registry_azure.go
  # AZURE_ACR_USERNAME/PASSWORD) — avoids an AcrPull RBAC assignment (Owner-only).
  admin_enabled = true
  tags          = var.tags
}

########################################
# Secrets (generated)
########################################
resource "random_password" "postgres" {
  length  = 24
  special = false
}

resource "random_password" "clickhouse" {
  length  = 24
  special = false
}

########################################
# Key Vault — connection secrets for the compute tier.
# Uses ACCESS POLICIES (not RBAC): creating RBAC role assignments needs
# Microsoft.Authorization/roleAssignments/write (Owner), which the deployer
# lacks; access policies are set on the vault itself (Contributor is enough).
########################################
resource "random_string" "kv" {
  length  = 6
  special = false
  upper   = false
}

resource "azurerm_key_vault" "this" {
  name                       = "${var.prefix}-kv-${random_string.kv.result}"
  location                   = azurerm_resource_group.this.location
  resource_group_name        = azurerm_resource_group.this.name
  tenant_id                  = data.azurerm_client_config.current.tenant_id
  sku_name                   = "standard"
  rbac_authorization_enabled = false
  tags                       = var.tags

  access_policy {
    tenant_id          = data.azurerm_client_config.current.tenant_id
    object_id          = data.azurerm_client_config.current.object_id
    secret_permissions = ["Get", "List", "Set", "Delete", "Purge", "Recover"]
  }
}

resource "azurerm_key_vault_secret" "pg_connection_string" {
  name         = "postgres-connection-string"
  key_vault_id = azurerm_key_vault.this.id
  value        = "postgres://${var.pg_admin_username}:${random_password.postgres.result}@${azurerm_network_interface.clickhouse.private_ip_address}:5432/postgres?sslmode=disable"
}

resource "azurerm_key_vault_secret" "redis_url" {
  name         = "redis-url"
  key_vault_id = azurerm_key_vault.this.id
  value        = "${azurerm_network_interface.clickhouse.private_ip_address}:6379"
}

resource "azurerm_key_vault_secret" "clickhouse_password" {
  name         = "clickhouse-password"
  key_vault_id = azurerm_key_vault.this.id
  value        = random_password.clickhouse.result
}

########################################
# Data node — self-hosted Postgres + Redis + ClickHouse on one in-VNet VM.
# Managed Azure PostgreSQL is offer-restricted on this subscription in this
# region, so Postgres runs here too (private, no public data ports). For
# production, split Postgres to its own VM / request the managed-PG exception.
########################################
resource "azurerm_public_ip" "clickhouse" {
  name                = "${var.prefix}-data-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_interface" "clickhouse" {
  name                = "${var.prefix}-data-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.data.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.clickhouse.id
  }
}

resource "azurerm_linux_virtual_machine" "clickhouse" {
  name                = "${var.prefix}-data"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = var.clickhouse_vm_size
  admin_username      = var.clickhouse_admin_username
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.clickhouse.id]

  admin_ssh_key {
    username   = var.clickhouse_admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 128
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/files/clickhouse-cloud-init.yaml.tftpl", {
    clickhouse_user     = var.clickhouse_admin_username
    clickhouse_password = random_password.clickhouse.result
    postgres_user       = var.pg_admin_username
    postgres_password   = random_password.postgres.result
  }))

  boot_diagnostics {}
}
