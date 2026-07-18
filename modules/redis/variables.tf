variable "name" {
  description = "Replication group identifier and base name for dependent resources (e.g. `myapp-staging-redis`)."
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
  description = "Custom node configuration, alternative to `size`. num_nodes counts primary + replicas."
  type = object({
    node_type = string
    num_nodes = optional(number, 1)
  })
  default  = null
  nullable = true
}

variable "engine_version" {
  description = "Redis engine version."
  type        = string
  default     = "7.1"
}

variable "parameter_group_family" {
  description = "ElastiCache parameter group family, must match engine_version."
  type        = string
  default     = "redis7"
}

variable "parameters" {
  description = "Parameters applied to the dedicated parameter group. noeviction by default: as a Sidekiq/queue backend Redis must not silently drop keys under memory pressure."
  type = list(object({
    name  = string
    value = string
  }))
  default = [
    { name = "maxmemory-policy", value = "noeviction" }
  ]
}

variable "multi_az_enabled" {
  description = "Enable Multi-AZ with automatic failover. Requires a custom `node` with num_nodes >= 2."
  type        = bool
  default     = false

  validation {
    condition     = !var.multi_az_enabled || try(var.node.num_nodes, 1) >= 2
    error_message = "multi_az_enabled requires node.num_nodes >= 2 (a replica to fail over to)."
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
