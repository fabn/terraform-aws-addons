# PostgreSQL addon: Aurora PostgreSQL Serverless v2 via the official
# terraform-aws-modules/rds-aurora module. The admin password is generated
# per instance and lives only in TF state + the caller's Secret,
# Heroku-addon style. Sibling of the mysql addon: same contract, same size
# presets, so a stack can pick either database interchangeably.

locals {
  # Heroku-style preset sizes, expressed in Aurora Capacity Units
  # (1 ACU = 2 GiB RAM, CPU proportional). mini/small keep min_capacity = 0
  # so the cluster auto-pauses when idle and scales to zero; medium/large
  # keep a warm floor to avoid resume latency on production traffic.
  sizes = {
    mini   = { min_capacity = 0, max_capacity = 1, seconds_until_auto_pause = 300 }
    small  = { min_capacity = 0, max_capacity = 2, seconds_until_auto_pause = 300 }
    medium = { min_capacity = 0.5, max_capacity = 4, seconds_until_auto_pause = null }
    large  = { min_capacity = 1, max_capacity = 8, seconds_until_auto_pause = null }
  }

  scaling = var.size != null ? local.sizes[var.size] : var.scaling
  # PostgreSQL database names cannot contain hyphens, cluster names can.
  database = coalesce(var.database, replace(var.name, "-", "_"))

  security_group_ingress_rules = merge(
    { for i, cidr in var.allowed_cidr_blocks :
    "cidr_${i}" => { description = "PostgreSQL from ${cidr}", cidr_ipv4 = cidr } },
    { for i, sg in var.allowed_security_group_ids :
    "sg_${i}" => { description = "PostgreSQL from peer security group", referenced_security_group_id = sg } },
  )
}

resource "random_password" "admin" {
  length = 32
  # No special characters so DATABASE_URL needs no percent-encoding.
  special = false
}

# https://github.com/terraform-aws-modules/terraform-aws-rds-aurora
module "cluster" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 10.0"

  name = var.name

  engine         = "aurora-postgresql"
  engine_version = var.engine_version
  # Serverless v2 clusters run in provisioned mode with db.serverless
  # instances; capacity comes from serverlessv2_scaling_configuration.
  engine_mode                        = "provisioned"
  cluster_instance_class             = "db.serverless"
  serverlessv2_scaling_configuration = local.scaling
  # First instance is the writer, every extra one is a reader replica.
  # Performance insights is an instance-level setting on Aurora.
  instances = { for i in range(1 + var.replicas) : tostring(i + 1) => {
    performance_insights_enabled          = var.monitoring_enabled
    performance_insights_retention_period = var.monitoring_enabled ? 7 : null
  } }

  database_name = local.database
  # The password stays out of the cluster state (write-only argument); the
  # generated random_password holds the value the outputs compose.
  master_username             = var.username
  manage_master_user_password = false
  master_password_wo          = random_password.admin.result
  master_password_wo_version  = 1

  # Network: private subnets only, access granted to explicit peers.
  create_db_subnet_group       = true
  subnets                      = var.subnet_ids
  vpc_id                       = var.vpc_id
  security_group_ingress_rules = local.security_group_ingress_rules

  # Monitoring: enhanced monitoring + database insights (performance
  # insights is per instance, see the instances map).
  create_monitoring_role      = var.monitoring_enabled
  cluster_monitoring_interval = var.monitoring_enabled ? 60 : 0
  database_insights_mode      = var.monitoring_enabled ? "standard" : null

  # Slow query log: log_min_duration_statement is the PostgreSQL equivalent
  # of the MySQL slow query log — every statement running longer than the
  # threshold is written to the postgresql log and exported to CloudWatch
  # (log group created here so retention is managed). It is a dynamic cluster
  # parameter, so it never keeps a scale-to-0 cluster from pausing.
  enabled_cloudwatch_logs_exports = var.slow_query_log ? ["postgresql"] : []
  create_cloudwatch_log_group     = var.slow_query_log
  cluster_parameter_group = !var.slow_query_log ? null : {
    family = var.cluster_family
    parameters = [
      # log_min_duration_statement is in milliseconds; long_query_time stays
      # in seconds for parity with the mysql addon.
      { name = "log_min_duration_statement", value = tostring(var.long_query_time * 1000) },
    ]
  }

  # Explicit params
  apply_immediately       = true
  storage_encrypted       = true
  copy_tags_to_snapshot   = true
  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot

  tags = var.tags
}
