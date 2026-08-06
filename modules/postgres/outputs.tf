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

# Empty when the cluster was restored and the caller did not pass
# `source_master_password`: the credential is then the source's, and the addon was
# never told it. That is the honest answer rather than a degraded one — a
# fabricated URL would fail at connect time instead of here.
output "sensitive_env" {
  description = "Credential vars (DATABASE_URL uses the postgresql scheme expected by the Rails pg adapter). Empty when a restored cluster was given no source_master_password."
  sensitive   = true
  # tomap on both branches so the output keeps one type. A bare `{}` against a
  # populated object leaves Terraform unifying two different object types, which
  # surfaces as a type error in the caller rather than here.
  value = local.password == null ? tomap({}) : tomap({
    DATABASE_URL = "postgresql://${var.username}:${local.password}@${module.cluster.cluster_endpoint}:5432/${local.database}"
    PGPASSWORD   = local.password
  })
}

output "host" {
  description = "Writer endpoint of the cluster."
  value       = module.cluster.cluster_endpoint
}

output "reader_host" {
  description = "Reader endpoint of the cluster (load-balances across replicas; equals the writer on single-instance clusters)."
  value       = module.cluster.cluster_reader_endpoint
}

# The cluster's lineage, for callers that need to tell an empty database from a
# copy of one — and for making the mode visible in a plan at all, since the
# restore arguments themselves are not readable back off the module.
output "restored_from" {
  description = "How the cluster was created: null when empty, otherwise the restore mode (copy-on-write, full-copy or snapshot) and its source."
  value = !local.restored ? null : {
    mode   = var.clone_from != null ? coalesce(var.clone_from.restore_type, "copy-on-write") : "snapshot"
    source = var.clone_from != null ? coalesce(var.clone_from.source_cluster_identifier, var.clone_from.source_cluster_resource_id) : var.snapshot_identifier
  }
}

output "database" {
  description = "Name of the database the connection vars point at (created here, or the source's on a restored cluster)."
  value       = local.database
}

output "username" {
  description = "Master username the connection vars use (created here, or the source's on a restored cluster)."
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
