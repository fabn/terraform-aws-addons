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
  description = "Enable TLS in transit (clients must connect with rediss://). Off by default: traffic stays inside the VPC."
  type        = bool
  default     = false
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
