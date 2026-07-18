# MySQL addon: Aurora MySQL Serverless v2 via the battle-tested
# cloudposse/rds-cluster module. The admin password is generated per
# instance and lives only in TF state + the caller's Secret, Heroku-addon
# style.

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
  # MySQL schema names cannot contain hyphens, cluster names can.
  database = coalesce(var.database, replace(var.name, "-", "_"))
}

resource "random_password" "admin" {
  length = 32
  # No special characters so DATABASE_URL needs no percent-encoding.
  special = false
}

# https://github.com/cloudposse/terraform-aws-rds-cluster
module "cluster" {
  source  = "cloudposse/rds-cluster/aws"
  version = "2.3.0"

  name = var.name

  engine         = "aurora-mysql"
  engine_version = var.engine_version
  cluster_family = var.cluster_family
  # Serverless v2 clusters run in provisioned mode with db.serverless
  # instances; capacity comes from serverlessv2_scaling_configuration.
  engine_mode                        = "provisioned"
  instance_type                      = "db.serverless"
  serverlessv2_scaling_configuration = local.scaling
  # First instance is the writer, every extra one is a reader replica.
  cluster_size = var.cluster_size

  db_name        = local.database
  admin_user     = var.username
  admin_password = random_password.admin.result

  # Network: private subnets only, access granted to explicit peers.
  subnets             = var.subnet_ids
  vpc_id              = var.vpc_id
  allowed_cidr_blocks = var.allowed_cidr_blocks
  security_groups     = var.allowed_security_group_ids

  # Monitoring: enhanced monitoring + performance/database insights. Key
  # must not be passed when performance insights is disabled.
  rds_monitoring_interval               = var.monitoring_enabled ? 60 : 0
  enhanced_monitoring_role_enabled      = var.monitoring_enabled
  performance_insights_enabled          = var.monitoring_enabled
  performance_insights_retention_period = var.monitoring_enabled ? 7 : null
  database_insights_mode                = var.monitoring_enabled ? "standard" : null

  # Explicit params
  apply_immediately          = true
  publicly_accessible        = false
  auto_minor_version_upgrade = true
  storage_encrypted          = true
  copy_tags_to_snapshot      = true
  deletion_protection        = var.deletion_protection
  skip_final_snapshot        = var.skip_final_snapshot

  # No cluster_parameters on purpose: binlog_format would keep a scale-to-0
  # cluster from ever pausing.

  tags = var.tags
}
