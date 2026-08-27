# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials.

# REDIS_URL travels in one map or the other, never both: with an auth token the
# URL embeds a credential and belongs in `sensitive_env`, and a key published
# twice would reach the consumer as a ConfigMap and a Secret disagreeing about
# the same variable.
#
# tomap on every branch so each output keeps one type — a bare `{}` against a
# populated object leaves Terraform unifying two different object types, which
# surfaces as a type error in the caller rather than here.
output "env" {
  description = "Plaintext connection vars for Rails/Sidekiq. The scheme follows transit encryption (redis:// or rediss://). Empty when an auth token is set: REDIS_URL then carries a credential and moves to sensitive_env."
  value = var.auth_token_enabled ? tomap({}) : tomap({
    REDIS_URL = local.url
  })
}

output "sensitive_env" {
  description = "Credential vars. Empty unless auth_token_enabled is set, since a Redis reached over a security group alone has no credentials to publish."
  sensitive   = true
  value = !var.auth_token_enabled ? tomap({}) : tomap({
    REDIS_URL        = "${local.scheme}://:${local.auth_token}@${local.endpoint}"
    REDIS_AUTH_TOKEN = local.auth_token
  })
}

output "auth_token" {
  description = "Generated AUTH token; null when auth_token_enabled is off. For a caller that has to park it somewhere its clients can reach (Secrets Manager, a Kubernetes Secret) rather than pass `sensitive_env` straight through."
  sensitive   = true
  value       = local.auth_token
}

output "transit_encryption_enabled" {
  description = "Whether clients must connect over TLS (rediss://)."
  value       = var.transit_encryption_enabled
}

output "transit_encryption_mode" {
  description = "TLS enforcement mode (preferred or required); null when AWS chose it."
  value       = var.transit_encryption_mode
}

output "auth_token_enabled" {
  description = "Whether the replication group requires an AUTH token."
  value       = var.auth_token_enabled
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

output "log_delivery_configuration" {
  description = "Log delivery configuration attached to the replication group (empty when `slow_log` is off)."
  value       = local.log_delivery_configuration
}

output "slow_log_group_name" {
  description = "CloudWatch log group receiving the slow log (null when `slow_log` is off)."
  value       = try(module.redis.cloudwatch_log_groups["slow-log"].name, null)
}

output "apply_immediately" {
  description = "Whether modifications are applied right away or deferred to the maintenance window."
  value       = var.apply_immediately
}
