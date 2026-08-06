# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials.
#
# MEMCACHED_SERVERS is a plain host:port server list, deliberately NOT a
# `memcached://…` URL: memcached clients (dalli et al.) parse a host:port list,
# not a URI scheme — unlike redis:// / postgresql:// whose clients do parse the
# scheme, so prefixing one here would only force the app to strip it. This
# matches the MemCachier/Heroku server-list convention and the in-cluster
# memcached addon of fabn/formation/kubernetes, so an in-cluster / managed swap
# stays invisible to the app.
output "env" {
  description = "Plaintext connection vars for the application cache store: comma-separated host:port server list of every cache node."
  value = {
    MEMCACHED_SERVERS = join(",", [for node in module.memcached.cluster_cache_nodes : "${node.address}:${node.port}"])
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

output "apply_immediately" {
  description = "Whether modifications are applied right away or deferred to the maintenance window."
  value       = var.apply_immediately
}
