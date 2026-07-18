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
  description = "Custom node configuration, alternative to `size`. Multi-node clusters are spread cross-AZ; clients see every node through MEMCACHED_SERVER_URL."
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
