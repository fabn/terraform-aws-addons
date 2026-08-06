# MySQL addon: Aurora MySQL Serverless v2 via the official
# terraform-aws-modules/rds-aurora module. The admin password is generated
# per instance and lives only in TF state + the caller's Secret,
# Heroku-addon style.

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

  # Each falls back to the old single flag, so callers that never set them keep
  # exactly the behaviour they had.
  enhanced_monitoring  = coalesce(var.enhanced_monitoring, var.monitoring_enabled)
  performance_insights = coalesce(var.performance_insights, var.monitoring_enabled)
  # MySQL schema names cannot contain hyphens, cluster names can.
  database = coalesce(var.database, replace(var.name, "-", "_"))

  # The addon's own parameters first, the caller's after, so a caller can
  # override one of ours by restating it — last write wins in the parameter
  # group, and the alternative would be a silent duplicate.
  cluster_parameters = concat(
    !var.slow_query_log ? [] : [
      { name = "slow_query_log", value = "1", apply_method = null },
      { name = "long_query_time", value = tostring(var.long_query_time), apply_method = null },
      { name = "log_output", value = "FILE", apply_method = null },
    ],
    [for p in var.cluster_parameters : {
      name         = p.name
      value        = p.value
      apply_method = p.apply_method
    }],
  )

  security_group_ingress_rules = merge(
    { for i, cidr in var.allowed_cidr_blocks :
    "cidr_${i}" => { description = "MySQL from ${cidr}", cidr_ipv4 = cidr } },
    { for i, sg in var.allowed_security_group_ids :
    "sg_${i}" => { description = "MySQL from peer security group", referenced_security_group_id = sg } },
  )
}

# Not created when RDS manages the master password: there would be nothing to do
# with the value, and generating a credential nobody uses is worse than not
# generating one.
resource "random_password" "admin" {
  count = var.manage_master_user_password ? 0 : 1

  length = 32
  # No special characters so DATABASE_URL needs no percent-encoding.
  special = false
}

# https://github.com/terraform-aws-modules/terraform-aws-rds-aurora
module "cluster" {
  source  = "terraform-aws-modules/rds-aurora/aws"
  version = "~> 10.0"

  name = var.name

  engine         = "aurora-mysql"
  engine_version = var.engine_version
  # Serverless v2 clusters run in provisioned mode with db.serverless
  # instances; capacity comes from serverlessv2_scaling_configuration.
  engine_mode                        = "provisioned"
  cluster_instance_class             = "db.serverless"
  serverlessv2_scaling_configuration = local.scaling
  # First instance is the writer, every extra one is a reader replica.
  # Performance insights is an instance-level setting on Aurora.
  instances = { for i in range(1 + var.replicas) : tostring(i + 1) => {
    performance_insights_enabled          = local.performance_insights
    performance_insights_retention_period = local.performance_insights ? 7 : null
  } }

  database_name = local.database
  # Two ways to hold the master credential, and the choice belongs to the caller
  # (see var.manage_master_user_password). Generated here, the password stays out
  # of the cluster state through the write-only argument and the random_password
  # holds the value the outputs compose. Managed by RDS, none of that applies —
  # the password is minted, stored and rotated on the service side, and Terraform
  # never learns it.
  master_username             = var.username
  manage_master_user_password = var.manage_master_user_password
  master_password_wo          = one(random_password.admin[*].result)
  master_password_wo_version  = var.manage_master_user_password ? null : 1

  # Network: private subnets only, access granted to explicit peers.
  create_db_subnet_group       = true
  subnets                      = var.subnet_ids
  vpc_id                       = var.vpc_id
  security_group_ingress_rules = local.security_group_ingress_rules

  # Monitoring: enhanced monitoring + database insights (performance
  # insights is per instance, see the instances map).
  # The role and the interval are the enhanced-monitoring half. database_insights
  # rides with Performance Insights: it is the console layer over the same data
  # and needs no role either.
  create_monitoring_role      = local.enhanced_monitoring
  cluster_monitoring_interval = local.enhanced_monitoring ? 60 : 0
  database_insights_mode      = local.performance_insights ? "standard" : null

  # Slow query log: enabled through the cluster parameter group and exported to
  # CloudWatch (log group created here so retention is managed). The group is
  # shared with whatever the caller passes in var.cluster_parameters, so it also
  # exists when the slow query log is off but extra parameters are not.
  enabled_cloudwatch_logs_exports = var.slow_query_log ? ["slowquery"] : []
  create_cloudwatch_log_group     = var.slow_query_log
  cluster_parameter_group = length(local.cluster_parameters) == 0 ? null : {
    family     = var.cluster_family
    parameters = local.cluster_parameters
  }

  enable_http_endpoint = var.enable_http_endpoint

  # Explicit params
  apply_immediately       = true
  storage_encrypted       = true
  copy_tags_to_snapshot   = true
  backup_retention_period = var.backup_retention_period
  deletion_protection     = var.deletion_protection
  skip_final_snapshot     = var.skip_final_snapshot

  # Maintenance/backup windows (UTC); null lets AWS pick a random window.
  preferred_maintenance_window = var.preferred_maintenance_window
  preferred_backup_window      = var.preferred_backup_window

  tags = var.tags
}
