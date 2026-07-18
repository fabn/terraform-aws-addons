# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials. MEMCACHIER_SERVERS is the Heroku-legacy var name kept for
# config parity across deploy targets (same convention as the in-cluster
# memcached addon of the formation module).

output "env" {
  description = "Plaintext connection vars for the application cache store: comma-separated host:port list of every cache node."
  value = {
    MEMCACHIER_SERVERS = join(",", [for node in module.memcached.cluster_cache_nodes : "${node.address}:${node.port}"])
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
