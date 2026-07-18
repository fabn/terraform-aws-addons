# The merged env vars of every enabled addon: plug them straight into the
# formation module (`env` / `secret_env`), Heroku-addon style.

output "env" {
  description = "Merged plaintext config vars of every enabled addon."
  value = merge(
    try(module.mysql[0].env, {}),
    try(module.postgres[0].env, {}),
    try(module.redis[0].env, {}),
    try(module.memcached[0].env, {}),
  )
}

output "sensitive_env" {
  description = "Merged credential vars of every enabled addon."
  sensitive   = true
  value = merge(
    try(module.mysql[0].sensitive_env, {}),
    try(module.postgres[0].sensitive_env, {}),
    try(module.redis[0].sensitive_env, {}),
    try(module.memcached[0].sensitive_env, {}),
  )
}

output "mysql" {
  description = "MySQL addon connection details; null when the addon is not enabled."
  value = local.mysql == null ? null : {
    host               = module.mysql[0].host
    reader_host        = module.mysql[0].reader_host
    database           = module.mysql[0].database
    username           = module.mysql[0].username
    cluster_identifier = module.mysql[0].cluster_identifier
    security_group_id  = module.mysql[0].security_group_id
    scaling            = module.mysql[0].scaling

    preferred_maintenance_window = module.mysql[0].preferred_maintenance_window
    preferred_backup_window      = module.mysql[0].preferred_backup_window
  }
}

output "postgres" {
  description = "PostgreSQL addon connection details; null when the addon is not enabled."
  value = local.postgres == null ? null : {
    host               = module.postgres[0].host
    reader_host        = module.postgres[0].reader_host
    database           = module.postgres[0].database
    username           = module.postgres[0].username
    cluster_identifier = module.postgres[0].cluster_identifier
    security_group_id  = module.postgres[0].security_group_id
    scaling            = module.postgres[0].scaling

    preferred_maintenance_window = module.postgres[0].preferred_maintenance_window
    preferred_backup_window      = module.postgres[0].preferred_backup_window
  }
}

output "redis" {
  description = "Redis addon connection details; null when the addon is not enabled."
  value = local.redis == null ? null : {
    host              = module.redis[0].host
    reader_host       = module.redis[0].reader_host
    security_group_id = module.redis[0].security_group_id
    engine            = module.redis[0].engine
    node_type         = module.redis[0].node_type
    replicas          = module.redis[0].replicas

    maintenance_window = module.redis[0].maintenance_window
  }
}

output "memcached" {
  description = "Memcached addon connection details; null when the addon is not enabled."
  value = local.memcached == null ? null : {
    host              = module.memcached[0].host
    security_group_id = module.memcached[0].security_group_id
    node              = module.memcached[0].node

    maintenance_window = module.memcached[0].maintenance_window
  }
}
