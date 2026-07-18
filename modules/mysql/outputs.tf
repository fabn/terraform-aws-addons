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

output "sensitive_env" {
  description = "Credential vars (DATABASE_URL uses the mysql2 scheme expected by the Rails mysql2 adapter)."
  sensitive   = true
  value = {
    DATABASE_URL   = "mysql2://${var.username}:${random_password.admin.result}@${module.cluster.cluster_endpoint}:3306/${local.database}"
    MYSQL_PASSWORD = random_password.admin.result
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
