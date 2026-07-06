########################################
# Compute tier: control node (Nomad server + API + client-proxy) and an
# orchestrator VM Scale Set (Nomad clients, each running the orchestrator +
# Firecracker). Nomad-only (no Consul): the API discovers orchestrators via
# Nomad's /v1/nodes (SERVICE_DISCOVERY_PROVIDER=nomad, node pool "default").
########################################

locals {
  control_ip = "10.90.1.10" # static so orchestrator nodes can retry_join Nomad

  # Config shared by both node roles, injected into cloud-init. Connection info
  # points at the already-deployed data tier; storage/registry use key auth.
  node_env = {
    data_ip            = azurerm_network_interface.clickhouse.private_ip_address
    pg_user            = var.pg_admin_username
    pg_password        = random_password.postgres.result
    ch_user            = var.clickhouse_admin_username
    ch_password        = random_password.clickhouse.result
    storage_account    = azurerm_storage_account.this.name
    storage_key        = azurerm_storage_account.this.primary_access_key
    template_bucket    = azurerm_storage_container.templates.name
    build_cache_bucket = azurerm_storage_container.build_cache.name
    acr_login_server   = azurerm_container_registry.this.login_server
    acr_repository     = var.acr_repository_name
    acr_username       = azurerm_container_registry.this.admin_username
    acr_password       = azurerm_container_registry.this.admin_password
    repo_url           = var.repo_url
    repo_ref           = var.repo_ref
    nomad_version      = var.nomad_version
    control_ip         = local.control_ip
  }
}

# --------------------------------------------------------------------------
# Outbound internet for the (private) compute subnet via a NAT gateway, so
# nodes can clone the repo, download Go/kernels/firecrackers, and pull from ACR.
# --------------------------------------------------------------------------
resource "azurerm_public_ip" "nat" {
  name                = "${var.prefix}-nat-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway" "this" {
  name                = "${var.prefix}-nat"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku_name            = "Standard"
  tags                = var.tags
}

resource "azurerm_nat_gateway_public_ip_association" "this" {
  nat_gateway_id       = azurerm_nat_gateway.this.id
  public_ip_address_id = azurerm_public_ip.nat.id
}

resource "azurerm_subnet_nat_gateway_association" "compute" {
  subnet_id      = azurerm_subnet.compute.id
  nat_gateway_id = azurerm_nat_gateway.this.id
}

# --------------------------------------------------------------------------
# NSG for the compute subnet
# --------------------------------------------------------------------------
resource "azurerm_network_security_group" "compute" {
  name                = "${var.prefix}-compute-nsg"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  # SDK traffic (API 3000 + sandbox proxy 3002), delivered via the load balancer.
  security_rule {
    name                       = "e2b-public"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["3000", "3002"]
    source_address_prefix      = var.admin_source_cidr
    destination_address_prefix = "*"
  }

  # Azure LB health probes.
  security_rule {
    name                       = "lb-probe"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  # Intra-VNet: API<->orchestrator gRPC (5008), Nomad (4646-4648), proxy, etc.
  security_rule {
    name                       = "intra-vnet"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "10.90.0.0/16"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "compute" {
  subnet_id                 = azurerm_subnet.compute.id
  network_security_group_id = azurerm_network_security_group.compute.id
}

# --------------------------------------------------------------------------
# Public load balancer -> control node (API 3000, sandbox proxy 3002)
# --------------------------------------------------------------------------
resource "azurerm_public_ip" "lb" {
  name                = "${var.prefix}-lb-pip"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = var.tags
}

resource "azurerm_lb" "this" {
  name                = "${var.prefix}-lb"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  sku                 = "Standard"
  tags                = var.tags

  frontend_ip_configuration {
    name                 = "public"
    public_ip_address_id = azurerm_public_ip.lb.id
  }
}

resource "azurerm_lb_backend_address_pool" "control" {
  name            = "control"
  loadbalancer_id = azurerm_lb.this.id
}

resource "azurerm_lb_probe" "api" {
  name            = "api-health"
  loadbalancer_id = azurerm_lb.this.id
  protocol        = "Http"
  port            = 3000
  request_path    = "/health"
}

resource "azurerm_lb_rule" "api" {
  name                           = "api"
  loadbalancer_id                = azurerm_lb.this.id
  protocol                       = "Tcp"
  frontend_port                  = 3000
  backend_port                   = 3000
  frontend_ip_configuration_name = "public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.control.id]
  probe_id                       = azurerm_lb_probe.api.id
}

resource "azurerm_lb_rule" "proxy" {
  name                           = "sandbox-proxy"
  loadbalancer_id                = azurerm_lb.this.id
  protocol                       = "Tcp"
  frontend_port                  = 3002
  backend_port                   = 3002
  frontend_ip_configuration_name = "public"
  backend_address_pool_ids       = [azurerm_lb_backend_address_pool.control.id]
  probe_id                       = azurerm_lb_probe.api.id
}

# --------------------------------------------------------------------------
# Control node — Nomad server + API + client-proxy
# --------------------------------------------------------------------------
resource "azurerm_network_interface" "control" {
  name                = "${var.prefix}-control-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  tags                = var.tags

  ip_configuration {
    name                          = "ipconfig"
    subnet_id                     = azurerm_subnet.compute.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.control_ip
  }
}

resource "azurerm_network_interface_backend_address_pool_association" "control" {
  network_interface_id    = azurerm_network_interface.control.id
  ip_configuration_name   = "ipconfig"
  backend_address_pool_id = azurerm_lb_backend_address_pool.control.id
}

resource "azurerm_linux_virtual_machine" "control" {
  name                = "${var.prefix}-control"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = var.control_vm_size
  admin_username      = var.clickhouse_admin_username
  tags                = var.tags

  network_interface_ids = [azurerm_network_interface.control.id]

  admin_ssh_key {
    username   = var.clickhouse_admin_username
    public_key = var.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Premium_LRS"
    disk_size_gb         = 64
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  custom_data = base64encode(templatefile("${path.module}/files/control-cloud-init.yaml.tftpl", merge(local.node_env, {
    admin_username = var.clickhouse_admin_username
    bootstrap_b64  = base64encode(file("${path.module}/files/control-bootstrap.sh"))
  })))

  boot_diagnostics {}

  depends_on = [azurerm_linux_virtual_machine.clickhouse]
}

# --------------------------------------------------------------------------
# Orchestrator VM Scale Set — Nomad clients running the orchestrator
# --------------------------------------------------------------------------
resource "azurerm_linux_virtual_machine_scale_set" "orchestrator" {
  name                = "${var.prefix}-orch"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  sku                 = var.orchestrator_vm_size
  instances           = var.orchestrator_instance_count
  admin_username      = var.clickhouse_admin_username
  upgrade_mode        = "Manual"
  tags                = var.tags

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

  network_interface {
    name    = "orch-nic"
    primary = true

    ip_configuration {
      name      = "ipconfig"
      primary   = true
      subnet_id = azurerm_subnet.compute.id
    }
  }

  custom_data = base64encode(templatefile("${path.module}/files/orchestrator-cloud-init.yaml.tftpl", merge(local.node_env, {
    admin_username = var.clickhouse_admin_username
    bootstrap_b64  = base64encode(file("${path.module}/files/orchestrator-bootstrap.sh"))
  })))

  depends_on = [azurerm_linux_virtual_machine.control]
}
