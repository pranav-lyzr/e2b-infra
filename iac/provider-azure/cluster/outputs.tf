output "postgres_connection_string" {
  description = "POSTGRES_CONNECTION_STRING for the E2B services (self-hosted, in-VNet)."
  value       = "postgres://${var.pg_admin_username}:${random_password.postgres.result}@${azurerm_network_interface.clickhouse.private_ip_address}:5432/postgres?sslmode=disable"
  sensitive   = true
}

output "redis_url" {
  description = "REDIS_URL (host:port) for the E2B services — self-hosted on the data VM."
  value       = "${azurerm_network_interface.clickhouse.private_ip_address}:6379"
}

output "storage_account_name" {
  description = "AZURE_STORAGE_ACCOUNT for storage_azure.go."
  value       = azurerm_storage_account.this.name
}

output "template_bucket_name" {
  description = "TEMPLATE_BUCKET_NAME (blob container)."
  value       = azurerm_storage_container.templates.name
}

output "build_cache_bucket_name" {
  description = "BUILD_CACHE_BUCKET_NAME (blob container)."
  value       = azurerm_storage_container.build_cache.name
}

output "acr_login_server" {
  description = "AZURE_ACR_LOGIN_SERVER for registry_azure.go."
  value       = azurerm_container_registry.this.login_server
}

output "key_vault_uri" {
  description = "Key Vault URI holding connection secrets."
  value       = azurerm_key_vault.this.vault_uri
}

output "clickhouse_private_ip" {
  description = "Private IP of the ClickHouse VM (reachable within the VNet)."
  value       = azurerm_network_interface.clickhouse.private_ip_address
}

output "clickhouse_public_ip" {
  value = azurerm_public_ip.clickhouse.ip_address
}
