# Redis addon: ElastiCache replication group via the official
# terraform-aws-modules/elasticache module. Single node by default, dedicated
# parameter group, no AUTH inside the VPC — access is controlled by the
# security group, until `auth_token_enabled` asks for a credential as well.
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

  # Per-engine defaults for version and parameter group family. Valkey is the
  # Redis-compatible engine ElastiCache prices lower; it keeps the same
  # protocol (REDIS_URL stays), only the parameter group family changes.
  engine_defaults = {
    redis  = { engine_version = "7.1", parameter_group_family = "redis7" }
    valkey = { engine_version = "8.0", parameter_group_family = "valkey8" }
  }
  engine_version         = coalesce(var.engine_version, local.engine_defaults[var.engine].engine_version)
  parameter_group_family = coalesce(var.parameter_group_family, local.engine_defaults[var.engine].parameter_group_family)

  security_group_rules = merge(
    { for i, cidr in var.allowed_cidr_blocks :
    "ingress_cidr_${i}" => { description = "Redis from ${cidr}", cidr_ipv4 = cidr } },
    { for i, sg in var.allowed_security_group_ids :
    "ingress_sg_${i}" => { description = "Redis from peer security group", referenced_security_group_id = sg } },
  )

  scheme   = var.transit_encryption_enabled ? "rediss" : "redis"
  endpoint = "${module.redis.replication_group_primary_endpoint_address}:6379"

  # Credential-free, so `env` stays plaintext config. The credentialed URL is
  # composed in `sensitive_env`, which is where a token belongs.
  url = "${local.scheme}://${local.endpoint}"

  auth_token = one(random_password.auth_token[*].result)

  # The snapshot window only makes sense when persistence is on; with
  # retention = 0 there are no snapshots to schedule.
  snapshot_window = var.snapshot_retention_limit > 0 ? var.snapshot_window : null

  # Opting out means removing the entry, not disabling its log group: upstream
  # falls back to the entry's `destination` when it creates no group, and that
  # attribute is unset here — a delivery configuration pointing nowhere.
  log_delivery_configuration = var.slow_log ? {
    slow-log = { destination_type = "cloudwatch-logs", log_format = "json" }
  } : {}
}

# The AUTH token, when one is asked for. A security group admits a whole CIDR
# or a whole peer group; a token is what narrows access to the clients actually
# given it, and it is the only way to do so on a shared network.
resource "random_password" "auth_token" {
  count = var.auth_token_enabled ? 1 : 0

  # ElastiCache accepts 16-128 printable characters. No special ones, so the
  # token needs no percent-encoding inside REDIS_URL.
  length  = 64
  special = false
}

# https://github.com/terraform-aws-modules/terraform-aws-elasticache
module "redis" {
  source  = "terraform-aws-modules/elasticache/aws"
  version = "~> 1.6"

  create_cluster           = false
  create_replication_group = true

  replication_group_id = var.name
  description          = "${var.name} redis addon"

  engine             = var.engine
  engine_version     = local.engine_version
  node_type          = local.node_type
  num_cache_clusters = 1 + var.replicas

  # Sentinel-equivalent HA: with at least one replica, failover promotes it
  # and the primary endpoint DNS follows.
  automatic_failover_enabled = var.replicas > 0
  multi_az_enabled           = var.multi_az_enabled
  at_rest_encryption_enabled = true
  transit_encryption_enabled = var.transit_encryption_enabled

  # AWS ties the two together: an auth token is accepted only on an encrypted
  # connection, which the variable's own validation enforces up front.
  auth_token = local.auth_token
  # ROTATE keeps the previous token valid alongside the new one, so clients that
  # have not been restarted yet still connect; retiring it is a second apply
  # with SET. Only ever reached by a token that changes — the generated one does
  # not, unless it is replaced deliberately.
  auth_token_update_strategy = var.auth_token_enabled ? "ROTATE" : null

  create_parameter_group = true
  parameter_group_family = local.parameter_group_family
  parameters = concat(
    [{ name = "maxmemory-policy", value = var.maxmemory_policy }],
    var.parameters,
  )

  log_delivery_configuration = local.log_delivery_configuration

  # Persistence = daily RDB snapshots; 0 disables them entirely.
  snapshot_retention_limit = var.snapshot_retention_limit
  snapshot_window          = local.snapshot_window

  # Weekly maintenance window (UTC); null lets AWS pick a random window.
  maintenance_window = var.maintenance_window

  apply_immediately = var.apply_immediately

  # Network: subnet group on private subnets, dedicated security group with
  # ingress limited to the declared peers.
  vpc_id               = var.vpc_id
  subnet_ids           = var.subnet_ids
  security_group_rules = local.security_group_rules

  tags = var.tags
}
