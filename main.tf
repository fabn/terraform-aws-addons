# Root wrapper, formation-style: one `addons` map entry per backing service,
# each deployed as an instance of the matching submodule under modules/.
# The merged `env` / `sensitive_env` outputs plug straight into the
# formation module's `env` / `secret_env` inputs, Heroku-addon style.
#
# Each submodule stays usable individually (and exposes more knobs than the
# wrapper); the wrapper covers the common case of one stack with a set of
# sized addons sharing network and lifecycle settings.

locals {
  mysql     = lookup(var.addons, "mysql", null)
  postgres  = lookup(var.addons, "postgres", null)
  redis     = lookup(var.addons, "redis", null)
  memcached = lookup(var.addons, "memcached", null)
}

module "mysql" {
  count  = local.mysql != null ? 1 : 0
  source = "./modules/mysql"

  name = "${var.name}-mysql"
  # Custom resources win over the preset; entries with neither get the
  # smallest plan, Heroku-style.
  size    = local.mysql.scaling != null ? null : coalesce(local.mysql.size, "mini")
  scaling = local.mysql.scaling

  # The default database is named after the stack, not the addon instance.
  database       = coalesce(local.mysql.database, replace(var.name, "-", "_"))
  username       = local.mysql.username
  replicas       = local.mysql.replicas
  slow_query_log = local.mysql.slow_query_log

  vpc_id                     = var.vpc_id
  subnet_ids                 = var.subnet_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks
  allowed_security_group_ids = var.allowed_security_group_ids

  monitoring_enabled  = var.production_grade
  deletion_protection = var.production_grade
  skip_final_snapshot = !var.production_grade

  tags = var.tags
}

module "postgres" {
  count  = local.postgres != null ? 1 : 0
  source = "./modules/postgres"

  name = "${var.name}-postgres"
  # Custom resources win over the preset; entries with neither get the
  # smallest plan, Heroku-style.
  size    = local.postgres.scaling != null ? null : coalesce(local.postgres.size, "mini")
  scaling = local.postgres.scaling

  # The default database is named after the stack, not the addon instance.
  database       = coalesce(local.postgres.database, replace(var.name, "-", "_"))
  username       = local.postgres.username
  replicas       = local.postgres.replicas
  slow_query_log = local.postgres.slow_query_log

  vpc_id                     = var.vpc_id
  subnet_ids                 = var.subnet_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks
  allowed_security_group_ids = var.allowed_security_group_ids

  monitoring_enabled  = var.production_grade
  deletion_protection = var.production_grade
  skip_final_snapshot = !var.production_grade

  tags = var.tags
}

module "redis" {
  count  = local.redis != null ? 1 : 0
  source = "./modules/redis"

  name = "${var.name}-redis"
  size = local.redis.node != null ? null : coalesce(local.redis.size, "mini")
  node = local.redis.node == null ? null : { node_type = local.redis.node.node_type }

  engine                   = local.redis.engine
  replicas                 = local.redis.replicas
  maxmemory_policy         = local.redis.maxmemory_policy
  snapshot_retention_limit = local.redis.snapshot_retention_limit

  vpc_id                     = var.vpc_id
  subnet_ids                 = var.subnet_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks
  allowed_security_group_ids = var.allowed_security_group_ids

  tags = var.tags
}

module "memcached" {
  count  = local.memcached != null ? 1 : 0
  source = "./modules/memcached"

  name = "${var.name}-memcached"
  size = local.memcached.node != null ? null : coalesce(local.memcached.size, "mini")
  node = local.memcached.node

  vpc_id                     = var.vpc_id
  subnet_ids                 = var.subnet_ids
  allowed_cidr_blocks        = var.allowed_cidr_blocks
  allowed_security_group_ids = var.allowed_security_group_ids

  tags = var.tags
}
