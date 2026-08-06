# Addon contract: `env` holds plaintext config vars, `sensitive_env` holds
# credentials. Consumers merge both into the app stack (env / secret_env of
# the formation module) Heroku-addon style.

output "env" {
  description = "Plaintext connection vars for the application."
  value = {
    MYSQL_HOST     = module.cluster.cluster_endpoint
    MYSQL_PORT     = "3306"
    MYSQL_USER     = var.username
    MYSQL_DATABASE = local.database
  }
}

# Empty when RDS manages the master password, and that is the honest answer
# rather than a degraded one: Terraform never learns the value, so there is no
# URL to compose and no password to hand over. A caller in that mode reads
# `master_user_secret_arn` and resolves the credential itself — which is the
# reason to ask for that mode in the first place.
output "sensitive_env" {
  description = "Credential vars (DATABASE_URL uses the mysql2 scheme expected by the Rails mysql2 adapter). Empty when manage_master_user_password is set."
  sensitive   = true
  # tomap on both branches so the output keeps one type. A bare `{}` against a
  # populated object leaves Terraform unifying two different object types, which
  # surfaces as a type error in the caller rather than here.
  value = var.manage_master_user_password ? tomap({}) : tomap({
    DATABASE_URL   = "mysql2://${var.username}:${one(random_password.admin[*].result)}@${module.cluster.cluster_endpoint}:3306/${local.database}"
    MYSQL_PASSWORD = one(random_password.admin[*].result)
  })
}

output "master_user_secret_arn" {
  description = "Secrets Manager secret holding the master credentials; null unless manage_master_user_password is set."
  value       = try(module.cluster.cluster_master_user_secret[0].secret_arn, null)
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

output "cluster_parameters" {
  description = "Resolved DB cluster parameters — the addon's own plus anything passed in `cluster_parameters`."
  value       = local.cluster_parameters
}

output "monitoring" {
  description = "Resolved monitoring flags — enhanced monitoring needs an IAM role, Performance Insights does not."
  value = {
    enhanced_monitoring  = var.enhanced_monitoring
    performance_insights = var.performance_insights
  }
}
