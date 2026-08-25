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

  # MySQL schema names cannot contain hyphens, cluster names can.
  database = coalesce(var.database, replace(var.name, "-", "_"))

  # A restored cluster arrives with the source's users, schemas and master
  # password already in it. Everything the addon would otherwise create — the
  # database, the master user, its password — is inherited, so the addon stops
  # asking for it: RDS rejects those arguments on a restore rather than
  # applying them.
  restored = var.clone_from != null || var.snapshot_identifier != null

  # The password `sensitive_env` publishes: generated here for an empty
  # cluster, the source's (as supplied by the caller) for a restored one, and
  # null when nobody here knows it — RDS-managed, or a restore whose caller
  # did not pass one.
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

  # The addon's own parameters first, the caller's after, so a caller can
  # override one of ours by restating it — last write wins in the parameter
  # group, and the alternative would be a silent duplicate.
  cluster_parameters = concat(
    !var.slow_query_log ? [] : [
      { name = "slow_query_log", value = "1", apply_method = null },
      { name = "long_query_time", value = tostring(var.long_query_time), apply_method = null },
      # pending-reboot, unlike its two neighbours, and not because the parameter
      # is static — it is dynamic. AWS reports `log_output` with Source "system"
      # on aurora-mysql8.0 and never records it as user-set: it does not appear
      # in the family's engine defaults at all, and its value is already FILE.
      #
      # So the write is accepted and discarded. A null apply_method makes the
      # provider send "immediate", the next refresh reads back the system value's
      # "pending-reboot", and the diff returns after every single apply — value
      # unchanged, forever. Matching what AWS reports is what ends the loop.
      { name = "log_output", value = "FILE", apply_method = "pending-reboot" },
    ],
    [for p in var.cluster_parameters : {
      name         = p.name
      value        = p.value
      apply_method = p.apply_method
    }],
  )

  # The ports are -1 rather than omitted, and that is load-bearing. The upstream
  # module resolves them with coalesce(from_port, to_port, local.port), so an
  # egress rule that leaves them out gets the *database port* — and AWS rejects
  # ports on an all-protocols rule outright: "You may not specify all protocols
  # and specific ports."
  #
  # Omitting them does not help either, because coalesce skips nulls and lands on
  # the same fallback. -1 is what AWS itself stores for an all-protocols rule, so
  # passing it explicitly both avoids the fallback and matches what a describe
  # returns, leaving no permanent diff.
  #
  # This fails at apply, not at plan: creating the rule works, and it is the
  # first *modify* — a description edit, a tag added anywhere on the cluster —
  # that sends the ports and gets the 400.
  security_group_egress_rules = {
    for i, cidr in var.egress_cidr_blocks :
    "cidr_${i}" => {
      description = "Outbound to ${cidr}"
      cidr_ipv4   = cidr
      ip_protocol = "-1"
      from_port   = -1
      to_port     = -1
    }
  }

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
  count = var.manage_master_user_password || local.restored ? 0 : 1

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
    performance_insights_enabled          = var.performance_insights
    performance_insights_retention_period = var.performance_insights ? 7 : null
  } }

  # Null on a restore: the schema comes from the source, and naming a
  # different one here is a change RDS cannot make (the argument forces a new
  # cluster rather than renaming anything).
  database_name = local.restored ? null : local.database
  # Three ways to hold the master credential. Generated here, the password stays
  # out of the cluster state through the write-only argument and the
  # random_password holds the value the outputs compose. Managed by RDS, none of
  # that applies — the password is minted, stored and rotated on the service
  # side, and Terraform never learns it. The choice between those two belongs to
  # the caller (see var.manage_master_user_password).
  #
  # Restored, there is no choice to make: the master user and its password come
  # from the source, so both arguments go null and the provider reads back what
  # the cluster actually came up with.
  master_username             = local.restored ? null : var.username
  manage_master_user_password = var.manage_master_user_password
  master_password_wo          = one(random_password.admin[*].result)
  master_password_wo_version  = var.manage_master_user_password || local.restored ? null : 1

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
  security_group_egress_rules  = local.security_group_egress_rules

  # Monitoring: enhanced monitoring + database insights (performance
  # insights is per instance, see the instances map).
  # The role and the interval are the enhanced-monitoring half. database_insights
  # rides with Performance Insights: it is the console layer over the same data
  # and needs no role either.
  create_monitoring_role      = var.enhanced_monitoring
  cluster_monitoring_interval = var.enhanced_monitoring ? 60 : 0
  database_insights_mode      = var.performance_insights ? "standard" : null

  # Slow query log: enabled through the cluster parameter group and exported to
  # CloudWatch (log group created here so retention is managed). The group is
  # shared with whatever the caller passes in var.cluster_parameters, so it also
  # exists when the slow query log is off but extra parameters are not.
  #
  # A restored cluster gets this group too, not the source's — deliberately. A
  # clone copies the source's data, and parameters are configuration rather than
  # data, so nothing carries them across on its own. Adopting them would be the
  # wrong default anyway: a clone of a cluster carrying binlog_format or
  # gtid_mode would come up configured as a replication source it is not, and
  # the binlog activity alone would keep a scale-to-zero clone from ever
  # pausing — which is most of the reason a per-PR clone is cheap. A caller who
  # genuinely wants the source's engine settings restates them in
  # var.cluster_parameters.
  enabled_cloudwatch_logs_exports = var.slow_query_log ? ["slowquery"] : []
  create_cloudwatch_log_group     = var.slow_query_log
  cluster_parameter_group = length(local.cluster_parameters) == 0 ? null : {
    family     = var.cluster_family
    parameters = local.cluster_parameters
  }

  enable_http_endpoint = var.enable_http_endpoint

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
