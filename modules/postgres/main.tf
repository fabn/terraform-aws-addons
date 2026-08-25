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

  # Serverless v2 unless the caller named a class. `instances` overrides this
  # per instance, which is what makes a mixed cluster expressible.
  default_instance_class = coalesce(var.instance_class, "db.serverless")

  # Instance "1" is the writer at creation; the rest are readers. The keys
  # address instances, not roles: a failover swaps which one is the writer and
  # nothing here follows it. They are also the identifier suffixes AWS assigns
  # (`<name>-<key>`), so renumbering an existing cluster replaces instances.
  instances = { for i in range(1 + var.replicas) : tostring(i + 1) => {
    instance_class = try(var.instances[tostring(i + 1)].instance_class, null)
    promotion_tier = try(var.instances[tostring(i + 1)].promotion_tier, null)
  } }

  instance_classes = { for k, v in local.instances : k => coalesce(v.instance_class, local.default_instance_class) }

  # The ACU range is the caller's, not a function of the default class. A mixed
  # cluster needs one for its Serverless v2 instances while the default class is
  # provisioned, and AWS keeps a range it was once given even after the last
  # serverless instance leaves the cluster — so dropping it from the
  # configuration would leave a diff that never applies.
  scaling = var.size != null ? local.sizes[var.size] : var.scaling
  # PostgreSQL database names cannot contain hyphens, cluster names can.
  database = coalesce(var.database, replace(var.name, "-", "_"))

  # A restored cluster arrives with the source's roles, databases and master
  # password already in it. Everything the addon would otherwise create — the
  # database, the master role, its password — is inherited, so the addon stops
  # asking for it: RDS rejects those arguments on a restore rather than
  # applying them.
  restored = var.clone_from != null || var.snapshot_identifier != null

  # The password `sensitive_env` publishes: generated here for an empty
  # cluster, the source's (as supplied by the caller) for a restored one, and
  # null when a restore's caller did not pass one.
  password = local.restored ? var.source_master_password : one(random_password.admin[*].result)

  # use_latest_restorable_time is what makes the clone track the source, so it
  # is the default unless the caller pinned a timestamp — AWS takes one or the
  # other, never both.
  clone_from = var.clone_from == null ? null : {
    source_cluster_identifier  = var.clone_from.source_cluster_identifier
    source_cluster_resource_id = var.clone_from.source_cluster_resource_id
    restore_to_time            = var.clone_from.restore_to_time
    restore_type               = coalesce(var.clone_from.restore_type, "copy-on-write")
    use_latest_restorable_time = var.clone_from.restore_to_time != null ? null : true
  }

  security_group_ingress_rules = merge(
    { for i, cidr in var.allowed_cidr_blocks :
    "cidr_${i}" => { description = "PostgreSQL from ${cidr}", cidr_ipv4 = cidr } },
    { for i, sg in var.allowed_security_group_ids :
    "sg_${i}" => { description = "PostgreSQL from peer security group", referenced_security_group_id = sg } },
  )
}

# Not created for a restored cluster: the master password is the source's, and
# generating a credential nobody uses is worse than not generating one.
resource "random_password" "admin" {
  count = local.restored ? 0 : 1

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
  # engine_mode is "provisioned" either way — it is the cluster's billing mode,
  # not the instance's, and Serverless v2 lives inside it. What actually picks
  # between the two is the instance class, per instance: db.serverless takes its
  # capacity from serverlessv2_scaling_configuration, a named class takes it from
  # the class. A cluster can hold both.
  engine_mode                        = "provisioned"
  cluster_instance_class             = local.default_instance_class
  serverlessv2_scaling_configuration = local.scaling
  # First instance is the writer, every extra one is a reader replica. A null
  # class falls back to cluster_instance_class upstream.
  # Performance insights is an instance-level setting on Aurora.
  instances = { for k, v in local.instances : k => {
    instance_class                        = v.instance_class
    promotion_tier                        = v.promotion_tier
    performance_insights_enabled          = var.monitoring_enabled
    performance_insights_retention_period = var.monitoring_enabled ? 7 : null
  } }

  # Null on a restore: the database comes from the source, and naming a
  # different one here is a change RDS cannot make (the argument forces a new
  # cluster rather than renaming anything).
  database_name = local.restored ? null : local.database
  # The password stays out of the cluster state (write-only argument); the
  # generated random_password holds the value the outputs compose. Restored,
  # the master role and its password come from the source, so both arguments go
  # null and the provider reads back what the cluster actually came up with.
  master_username             = local.restored ? null : var.username
  manage_master_user_password = false
  master_password_wo          = one(random_password.admin[*].result)
  master_password_wo_version  = local.restored ? null : 1

  # Cloning / restoring. Mutually exclusive (enforced on the variables), and
  # both fix the cluster's lineage at creation: changing either later replaces
  # the cluster.
  restore_to_point_in_time = local.clone_from
  snapshot_identifier      = var.snapshot_identifier

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
  #
  # A restored cluster gets this group too, not the source's — deliberately. A
  # clone copies the source's data, and parameters are configuration rather than
  # data, so nothing carries them across on its own. Adopting them would be the
  # wrong default anyway: a clone of a cluster set up for logical replication
  # would come up configured as something it is not, and the resulting activity
  # would keep a scale-to-zero clone from ever pausing — which is most of the
  # reason a per-PR clone is cheap.
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
  apply_immediately       = var.apply_immediately
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
