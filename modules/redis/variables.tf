variable "name" {
  description = "Replication group identifier and base name for dependent resources (e.g. `myapp-staging-redis`)."
  type        = string
}

variable "size" {
  description = "Heroku-style preset size (mini, small, medium, large) mapped to a cache node type. Set to null and pass `node` for a custom node type."
  type        = string
  default     = "mini"
  nullable    = true

  validation {
    condition     = var.size == null ? true : contains(["mini", "small", "medium", "large"], var.size)
    error_message = "size must be one of: mini, small, medium, large (or null when node is set)."
  }

  validation {
    condition     = (var.size == null) != (var.node == null)
    error_message = "Exactly one of size or node must be set: pass size = null when using a custom node."
  }
}

variable "node" {
  description = "Custom node type, alternative to `size`."
  type = object({
    node_type = string
  })
  default  = null
  nullable = true
}

variable "replicas" {
  description = "Number of read replicas alongside the primary. With replicas > 0 automatic failover is enabled (the ElastiCache equivalent of Sentinel: a replica is promoted and the primary endpoint DNS follows)."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.replicas >= 0 && var.replicas <= 5
    error_message = "replicas must be between 0 and 5."
  }
}

variable "maxmemory_policy" {
  description = "Redis eviction policy. noeviction (the default) suits queue backends that must not silently drop keys; use allkeys-lru (or another eviction policy) when Redis is a cache."
  type        = string
  default     = "noeviction"
  nullable    = false

  validation {
    condition     = contains(["noeviction", "allkeys-lru", "volatile-lru", "allkeys-lfu", "volatile-lfu", "allkeys-random", "volatile-random", "volatile-ttl"], var.maxmemory_policy)
    error_message = "maxmemory_policy must be a valid Redis eviction policy (noeviction, allkeys-lru, volatile-lru, allkeys-lfu, volatile-lfu, allkeys-random, volatile-random, volatile-ttl)."
  }
}

variable "snapshot_retention_limit" {
  description = "Days of daily RDB snapshots to retain — the ElastiCache form of persistence. Set 0 to opt out (recommended when Redis is a cache)."
  type        = number
  default     = 1
  nullable    = false
}

variable "snapshot_window" {
  description = "Daily UTC window when ElastiCache takes the RDB snapshot, format `hh24:mi-hh24:mi` (min 60 minutes, must not overlap the maintenance window). Ignored when snapshot_retention_limit = 0. Defaults to a nighttime slot before the maintenance window; set null to let AWS pick a random window."
  type        = string
  default     = "01:00-02:00"
  nullable    = true

  validation {
    condition     = var.snapshot_window == null ? true : can(regex("^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$", var.snapshot_window))
    error_message = "snapshot_window must look like hh24:mi-hh24:mi (UTC), e.g. 01:00-02:00."
  }
}

variable "engine" {
  description = "Cache engine: `redis` (Redis OSS) or `valkey`, the Redis-compatible engine ElastiCache offers at a lower price. Valkey speaks the same protocol, so `REDIS_URL` and clients keep working unchanged."
  type        = string
  default     = "redis"
  nullable    = false

  validation {
    condition     = contains(["redis", "valkey"], var.engine)
    error_message = "engine must be one of: redis, valkey."
  }
}

variable "engine_version" {
  description = "Engine version. Defaults to the engine's current major when null (7.1 for redis, 8.0 for valkey)."
  type        = string
  default     = null
  nullable    = true
}

variable "parameter_group_family" {
  description = "ElastiCache parameter group family, must match engine_version. Defaults to the engine's current family when null (redis7 for redis, valkey8 for valkey)."
  type        = string
  default     = null
  nullable    = true
}

variable "parameters" {
  description = "Extra parameters applied to the dedicated parameter group, merged after maxmemory_policy."
  type = list(object({
    name  = string
    value = string
  }))
  default = []
}

variable "slow_log" {
  description = "Deliver the Redis slow log to CloudWatch Logs (JSON) in a log group named `/aws/elasticache/<name>`. Turn off to keep the addon within ElastiCache permissions, or where the log is not wanted."
  type        = bool
  default     = true
  # Callers (the root wrapper) may forward null to mean "use the default".
  nullable = false
}

variable "maintenance_window" {
  description = "Weekly UTC window when AWS applies maintenance (engine upgrades, patches), format `ddd:hh24:mi-ddd:hh24:mi` (min 60 minutes). Defaults to a Monday-night slot so upgrades land off-peak; set null to let AWS pick a random window."
  type        = string
  default     = "mon:03:00-mon:04:00"
  nullable    = true

  validation {
    condition     = var.maintenance_window == null ? true : can(regex("^[A-Za-z]{3}:[0-9]{2}:[0-9]{2}-[A-Za-z]{3}:[0-9]{2}:[0-9]{2}$", var.maintenance_window))
    error_message = "maintenance_window must look like ddd:hh24:mi-ddd:hh24:mi (UTC), e.g. mon:03:00-mon:04:00."
  }
}

# Immediate by default, because that is what makes an addon predictable: a
# change to the configuration lands on the next apply, and the plan is the whole
# story.
#
# The exception is a production cache, where a handful of modifications — node
# type, engine version, replica count — restart or replace nodes and cost a
# failover. Set this to false and ElastiCache defers those to
# maintenance_window instead. Two things follow: non-disruptive changes still
# apply right away, and a deferred one stays pending on the AWS side until the
# window opens, so a later plan can look clean while the change has not landed
# yet.
variable "apply_immediately" {
  description = "Apply replication group modifications right away instead of deferring the disruptive ones to `maintenance_window`. Turn off on production caches where a failover should wait for the window."
  type        = bool
  default     = true
  nullable    = false
}

variable "multi_az_enabled" {
  description = "Spread primary and replicas across AZs with Multi-AZ failover. Requires replicas >= 1."
  type        = bool
  default     = false

  validation {
    condition     = !var.multi_az_enabled || var.replicas >= 1
    error_message = "multi_az_enabled requires replicas >= 1 (a replica to fail over to)."
  }
}

variable "transit_encryption_enabled" {
  description = "Enable TLS in transit (clients must connect with rediss://). Off by default: traffic stays inside the VPC. ElastiCache serves a certificate from a public CA, so clients need no trust configuration."
  type        = bool
  default     = false
  # Callers (the root wrapper) may forward null to mean "use the default".
  nullable = false
}

# What a security group cannot express: it admits a CIDR or a peer group, which
# on a shared network is every workload on it. A token narrows access to the
# clients actually given one.
#
# Turning it on is a replacement, not a modification: ElastiCache accepts a
# token only on an encrypted connection, and encryption in transit is settled
# when the replication group is created. Whatever is in the cache is lost with
# it.
variable "auth_token_enabled" {
  description = "Require an AUTH token. The addon generates one and publishes the credentialed `REDIS_URL` in `sensitive_env` instead of `env`. Requires transit_encryption_enabled."
  type        = bool
  default     = false
  nullable    = false

  validation {
    condition     = !var.auth_token_enabled || var.transit_encryption_enabled
    error_message = "auth_token_enabled requires transit_encryption_enabled: ElastiCache accepts an auth token only on an encrypted connection."
  }
}

variable "vpc_id" {
  description = "VPC where the replication group is created."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the cache subnet group (private subnets)."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach Redis."
  type        = list(string)
  default     = []
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach Redis."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
