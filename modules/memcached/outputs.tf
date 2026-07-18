# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials.

output "env" {
  description = "Plaintext connection vars for the application cache store: comma-separated memcached://host:port URL list of every cache node."
  value = {
    MEMCACHED_SERVER_URL = join(",", [for node in module.memcached.cluster_cache_nodes : "memcached://${node.address}:${node.port}"])
  }
}

output "sensitive_env" {
  description = "Always empty (no SASL — access is controlled by the security group); present to satisfy the addon contract."
  sensitive   = true
  value       = {}
}

output "host" {
  description = "Configuration endpoint DNS name of the cluster (for auto-discovery clients)."
  value       = module.memcached.cluster_address
}

output "security_group_id" {
  description = "ID of the security group protecting memcached."
  value       = module.memcached.security_group_id
}

output "node" {
  description = "Resolved node configuration (from `size` or `node`)."
  value       = local.node
}

output "maintenance_window" {
  description = "Weekly UTC maintenance window (null when AWS picks a random one)."
  value       = var.maintenance_window
}
