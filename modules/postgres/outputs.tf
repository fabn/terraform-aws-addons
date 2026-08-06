# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials. Consumers merge both into the app stack (env / secret_env of
# the formation module) Heroku-addon style. The PG* names mirror the
# in-cluster postgres addon of the formation module so the two stay
# interchangeable.

output "env" {
  description = "Plaintext connection vars for the application."
  value = {
    PGHOST     = module.cluster.cluster_endpoint
    PGPORT     = "5432"
    PGUSER     = var.username
    PGDATABASE = local.database
  }
}

output "sensitive_env" {
  description = "Credential vars (DATABASE_URL uses the postgresql scheme expected by the Rails pg adapter)."
  sensitive   = true
  value = {
    DATABASE_URL = "postgresql://${var.username}:${random_password.admin.result}@${module.cluster.cluster_endpoint}:5432/${local.database}"
    PGPASSWORD   = random_password.admin.result
  }
}

output "host" {
  description = "Writer endpoint of the cluster."
  value       = module.cluster.cluster_endpoint
}

output "reader_host" {
  description = "Reader endpoint of the cluster (load-balances across replicas; equals the writer on single-instance clusters)."
  value       = module.cluster.cluster_reader_endpoint
}

output "database" {
  description = "Name of the created database."
  value       = local.database
}

output "username" {
  description = "Master username."
  value       = var.username
}

output "cluster_identifier" {
  description = "Cluster identifier."
  value       = module.cluster.cluster_id
}

output "security_group_id" {
  description = "ID of the security group protecting the cluster."
  value       = module.cluster.security_group_id
}

output "scaling" {
  description = "Resolved Serverless v2 capacity range (from `size` or `scaling`)."
  value       = local.scaling
}

output "preferred_maintenance_window" {
  description = "Weekly UTC maintenance window (null when AWS picks a random one)."
  value       = var.preferred_maintenance_window
}

output "preferred_backup_window" {
  description = "Daily UTC automated-backup window (null when AWS picks a random one)."
  value       = var.preferred_backup_window
}

output "apply_immediately" {
  description = "Whether modifications are applied right away or deferred to the maintenance window."
  value       = var.apply_immediately
}
