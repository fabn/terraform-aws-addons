# Memcached addon: ElastiCache memcached cluster via the official
# terraform-aws-modules/elasticache module. Deliberately ephemeral (no
# snapshots — a node replacement cold-starts an empty cache and the app
# treats it as a miss), no SASL: access is controlled by the security group.

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
    "ingress_cidr_${i}" => { description = "Memcached from ${cidr}", cidr_ipv4 = cidr } },
    { for i, sg in var.allowed_security_group_ids :
    "ingress_sg_${i}" => { description = "Memcached from peer security group", referenced_security_group_id = sg } },
  )
}

# https://github.com/terraform-aws-modules/terraform-aws-elasticache
module "memcached" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.6"

  create_cluster           = true
  create_replication_group = false

  cluster_id = var.name

  engine          = "memcached"
  engine_version  = var.engine_version
  node_type       = local.node.node_type
  num_cache_nodes = local.node.num_nodes
  az_mode         = local.node.num_nodes > 1 ? "cross-az" : "single-az"

  # Plain memcached protocol: standard clients don't speak TLS.
  transit_encryption_enabled = false

  apply_immediately = true

  # Network: subnet group on private subnets, dedicated security group with
  # ingress limited to the declared peers.
  vpc_id               = var.vpc_id
  subnet_ids           = var.subnet_ids
  security_group_rules = local.security_group_rules

  tags = var.tags
}
