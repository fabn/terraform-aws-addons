# Redis addon: ElastiCache replication group via the official
# terraform-aws-modules/elasticache module. Single node by default, dedicated
# parameter group, no AUTH inside the VPC — access is controlled by the
# security group.
#
# The defaults suit a queue backend (Sidekiq): noeviction + daily snapshot.
# For a pure cache flip maxmemory_policy (e.g. allkeys-lru) and set
# snapshot_retention_limit = 0.
#
# There is no Redis Sentinel on ElastiCache: high availability is the
# managed equivalent — with replicas > 0 automatic failover promotes a
# replica and repoints the primary endpoint DNS, no sentinel-aware client
# needed (add multi_az_enabled for AZ-spread placement).

locals {
  # Heroku-style preset sizes mapped to Graviton cache node types.
  sizes = {
    mini   = "cache.t4g.micro"  # ~0.5 GiB
    small  = "cache.t4g.small"  # ~1.4 GiB
    medium = "cache.t4g.medium" # ~3.1 GiB
    large  = "cache.m7g.large"  # ~6.4 GiB
  }

  node_type = var.size != null ? local.sizes[var.size] : var.node.node_type

  security_group_rules = merge(
    { for i, cidr in var.allowed_cidr_blocks :
    "ingress_cidr_${i}" => { description = "Redis from ${cidr}", cidr_ipv4 = cidr } },
    { for i, sg in var.allowed_security_group_ids :
    "ingress_sg_${i}" => { description = "Redis from peer security group", referenced_security_group_id = sg } },
  )

  scheme = var.transit_encryption_enabled ? "rediss" : "redis"
}

# https://github.com/terraform-aws-modules/terraform-aws-elasticache
module "redis" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.6"

  create_cluster           = false
  create_replication_group = true

  replication_group_id = var.name
  description          = "${var.name} redis addon"

  engine             = "redis"
  engine_version     = var.engine_version
  node_type          = local.node_type
  num_cache_clusters = 1 + var.replicas

  # Sentinel-equivalent HA: with at least one replica, failover promotes it
  # and the primary endpoint DNS follows.
  automatic_failover_enabled = var.replicas > 0
  multi_az_enabled           = var.multi_az_enabled
  at_rest_encryption_enabled = true
  transit_encryption_enabled = var.transit_encryption_enabled

  create_parameter_group = true
  parameter_group_family = var.parameter_group_family
  parameters = concat(
    [{ name = "maxmemory-policy", value = var.maxmemory_policy }],
    var.parameters,
  )

  # Persistence = daily RDB snapshots; 0 disables them entirely.
  snapshot_retention_limit = var.snapshot_retention_limit

  apply_immediately = true

  # Network: subnet group on private subnets, dedicated security group with
  # ingress limited to the declared peers.
  vpc_id               = var.vpc_id
  subnet_ids           = var.subnet_ids
  security_group_rules = local.security_group_rules

  tags = var.tags
}
