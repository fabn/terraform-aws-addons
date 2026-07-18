# Redis addon: ElastiCache replication group via the official
# terraform-aws-modules/elasticache module. Single node by default, dedicated
# parameter group with noeviction (safe for Sidekiq queues), no AUTH inside
# the VPC — access is controlled by the security group.

locals {
  # Heroku-style preset sizes mapped to Graviton cache node types.
  sizes = {
    mini   = "cache.t4g.micro"  # ~0.5 GiB
    small  = "cache.t4g.small"  # ~1.4 GiB
    medium = "cache.t4g.medium" # ~3.1 GiB
    large  = "cache.m7g.large"  # ~6.4 GiB
  }

  node = var.size != null ? { node_type = local.sizes[var.size], num_nodes = 1 } : var.node

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
  node_type          = local.node.node_type
  num_cache_clusters = local.node.num_nodes

  multi_az_enabled           = var.multi_az_enabled
  at_rest_encryption_enabled = true
  transit_encryption_enabled = var.transit_encryption_enabled

  create_parameter_group = true
  parameter_group_family = var.parameter_group_family
  parameters             = var.parameters

  apply_immediately = true

  # Network: subnet group on private subnets, dedicated security group with
  # ingress limited to the declared peers.
  vpc_id               = var.vpc_id
  subnet_ids           = var.subnet_ids
  security_group_rules = local.security_group_rules

  tags = var.tags
}
