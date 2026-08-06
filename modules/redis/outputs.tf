# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials.

output "env" {
  description = "Plaintext connection vars for Rails/Sidekiq. The scheme follows transit encryption (redis:// or rediss://)."
  value = {
    REDIS_URL = "${local.scheme}://${module.redis.replication_group_primary_endpoint_address}:6379"
  }
}

output "sensitive_env" {
  description = "Always empty (no AUTH inside the VPC — access is controlled by the security group); present to satisfy the addon contract."
  sensitive   = true
  value       = {}
}

output "host" {
  description = "Primary endpoint of the replication group."
  value       = module.redis.replication_group_primary_endpoint_address
}

output "reader_host" {
  description = "Reader endpoint of the replication group (load-balances across replicas)."
  value       = module.redis.replication_group_reader_endpoint_address
}

output "security_group_id" {
  description = "ID of the security group protecting Redis."
  value       = module.redis.security_group_id
}

output "engine" {
  description = "Cache engine backing the replication group (redis or valkey)."
  value       = var.engine
}

output "parameter_group_family" {
  description = "Resolved parameter group family (from `engine` or an override)."
  value       = local.parameter_group_family
}

output "node_type" {
  description = "Resolved cache node type (from `size` or `node`)."
  value       = local.node_type
}

output "replicas" {
  description = "Number of read replicas."
  value       = var.replicas
}

output "maintenance_window" {
  description = "Weekly UTC maintenance window (null when AWS picks a random one)."
  value       = var.maintenance_window
}

output "snapshot_window" {
  description = "Daily UTC snapshot window (null when persistence is off or AWS picks a random one)."
  value       = local.snapshot_window
}

output "apply_immediately" {
  description = "Whether modifications are applied right away or deferred to the maintenance window."
  value       = var.apply_immediately
}
