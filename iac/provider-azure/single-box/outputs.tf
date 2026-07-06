output "public_ip" {
  description = "Public IP of the E2B box."
  value       = azurerm_public_ip.this.ip_address
}

output "ssh_command" {
  description = "SSH into the box."
  value       = "ssh ${var.admin_username}@${azurerm_public_ip.this.ip_address}"
}

output "e2b_api_url" {
  description = "Point the SDK's E2B_API_URL here."
  value       = "http://${azurerm_public_ip.this.ip_address}:3000"
}

output "e2b_sandbox_url" {
  description = "Point the SDK's E2B_SANDBOX_URL here."
  value       = "http://${azurerm_public_ip.this.ip_address}:3002"
}

output "capacity_plan" {
  description = "Resolved sizing for this deployment."
  value = {
    target_sessions    = var.sessions
    per_session_vcpu   = var.per_session_vcpu
    per_session_ram_mb = var.per_session_ram_mb
    vm_size            = var.vm_size
    nr_hugepages       = local.hugepages
    hugepages_ram_gb   = local.hugepages * 2 / 1024
    nbd_pool_size      = local.nbd_pool_size
    snapshot_cache_gb  = local.snapshot_cache_gb
  }
}

output "bootstrap_log_hint" {
  description = "Where to watch first-boot bootstrap progress."
  value       = "ssh in, then: sudo tail -f /var/log/e2b-bootstrap.log"
}
