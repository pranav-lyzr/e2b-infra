locals {
  # Huge pages are 2 MiB each. Reserve enough to back every session's RAM,
  # plus 15% overhead for Firecracker/jailer bookkeeping. Rounded up.
  hugepages = ceil(var.sessions * var.per_session_ram_mb / 2 * 1.15)

  # tmpfs snapshot cache ~ 1x total sandbox RAM (GB), capped for sanity.
  snapshot_cache_gb = min(96, ceil(var.sessions * var.per_session_ram_mb / 1024))

  # NBD device pool: each active NBD-backed sandbox needs a device; give margin.
  nbd_pool_size = max(64, var.sessions * 2)
  nbds_max      = max(128, var.sessions * 4)

  # Rendered once and passed to the OS via cloud-init. Kept in /etc/e2b/sizing.env
  # so bootstrap.sh and env-overrides.sh read a single source of truth.
  sizing_env = templatefile("${path.module}/files/sizing.env.tftpl", {
    sessions           = var.sessions
    per_session_vcpu   = var.per_session_vcpu
    per_session_ram_mb = var.per_session_ram_mb
    nr_hugepages       = local.hugepages
    nbd_pool_size      = local.nbd_pool_size
    nbds_max           = local.nbds_max
    snapshot_cache_gb  = local.snapshot_cache_gb
    repo_url           = var.repo_url
    repo_ref           = var.repo_ref
    admin_username     = var.admin_username
  })

  cloud_init = templatefile("${path.module}/cloud-init.yaml.tftpl", {
    sizing_env_b64       = base64encode(local.sizing_env)
    bootstrap_b64        = base64encode(file("${path.module}/files/bootstrap.sh"))
    env_overrides_b64    = base64encode(file("${path.module}/files/env-overrides.sh"))
    svc_infra_b64        = base64encode(file("${path.module}/files/e2b-infra.service"))
    svc_orchestrator_b64 = base64encode(file("${path.module}/files/e2b-orchestrator.service"))
    svc_api_b64          = base64encode(file("${path.module}/files/e2b-api.service"))
    svc_client_proxy_b64 = base64encode(file("${path.module}/files/e2b-client-proxy.service"))
    admin_username       = var.admin_username
  })
}

resource "azurerm_resource_group" "this" {
  name     = var.resource_group_name
  location = var.location
  tags     = var.tags
}

# --------------------------------------------------------------------------
# Networking
# --------------------------------------------------------------------------

resource "azurerm_virtual_network" "this" {
  name                = "${var.prefix}-vnet"
  address_space       = ["10.80.0.0/16"]
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags
}

resource "azurerm_subnet" "this" {
  name                 = "${var.prefix}-subnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.80.1.0/24"]
}

resource "azurerm_public_ip" "this" {
  name                = "${var.prefix}-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_network_security_group" "this" {
  name                = "${var.prefix}-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  security_rule {
    name                       = "ssh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = var.admin_source_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "e2b-api"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3000"
    source_address_prefix      = var.admin_source_cidr
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "e2b-sandbox-proxy"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3002"
    source_address_prefix      = var.admin_source_cidr
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_interface" "this" {
  name                = "${var.prefix}-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.this.id
    private_ip_address_allocation = "Dynamic"
    public_ip_address_id          = azurerm_public_ip.this.id
  }
}

resource "azurerm_network_interface_security_group_association" "this" {
  network_interface_id      = azurerm_network_interface.this.id
  network_security_group_id = azurerm_network_security_group.this.id
}

# --------------------------------------------------------------------------
# Compute
# --------------------------------------------------------------------------

resource "azurerm_linux_virtual_machine" "this" {
  name                = "${var.prefix}-box"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = var.vm_size
  admin_username      = var.admin_username
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.this.id]

  admin_ssh_key {
    username   = var.admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = var.os_disk_size_gb
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  # cloud-init bootstraps the entire local-provider stack on first boot.
  custom_data = base64encode(local.cloud_init)

  boot_diagnostics {}
}

# Dedicated data disk for template/build/snapshot storage (local providers).
resource "azurerm_managed_disk" "data" {
  name                 = "${var.prefix}-data"
  location             = azurerm_resource_group.this.location
  resource_group_name  = azurerm_resource_group.this.name
  storage_account_type = "Premium_LRS"
  create_option        = "Empty"
  disk_size_gb         = var.data_disk_size_gb
  tags                 = var.tags
}

resource "azurerm_virtual_machine_data_disk_attachment" "data" {
  managed_disk_id    = azurerm_managed_disk.data.id
  virtual_machine_id = azurerm_linux_virtual_machine.this.id
  lun                = 10
  caching            = "ReadWrite"
}
