variable "name" {
  description = "Cluster identifier and base name for dependent resources (e.g. `myapp-staging-memcached`)."
  type        = string
}

variable "size" {
  description = "Heroku-style preset size (mini, small, medium, large) mapped to a cache node type. Set to null and pass `node` for a custom node type / count."
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
  description = "Custom node configuration, alternative to `size`. Multi-node clusters are spread cross-AZ; clients see every node through MEMCACHED_SERVERS."
  type = object({
    node_type = string
    num_nodes = optional(number, 1)
  })
  default  = null
  nullable = true
}

variable "engine_version" {
  description = "Memcached engine version. Null lets AWS pick the latest."
  type        = string
  default     = null
  nullable    = true
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
# type, node count, engine version — replace nodes, and the replacements come up
# empty. This addon is ephemeral by design (a cold node is a miss the app
# absorbs), so the cost is a burst of misses rather than lost data; where that
# burst still needs to land off-peak, set this to false and ElastiCache defers
# those modifications to maintenance_window instead. A deferred change stays
# pending on the AWS side until the window opens, so a later plan can look clean
# while the change has not landed yet.
variable "apply_immediately" {
  description = "Apply cluster modifications right away instead of deferring the disruptive ones to `maintenance_window`. Turn off where the cold cache that follows a node replacement should wait for the window."
  type        = bool
  default     = true
  nullable    = false
}

variable "vpc_id" {
  description = "VPC where the cluster is created."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the cache subnet group (private subnets)."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach memcached."
  type        = list(string)
  default     = []
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach memcached."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
