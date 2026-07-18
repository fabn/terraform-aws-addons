variable "name" {
  description = "Stack name (e.g. `myapp-staging`). Addon resources are named `<name>-<addon>`; the default MySQL database is named after the stack."
  type        = string

  validation {
    condition     = length(var.name) > 0
    error_message = "name must not be empty."
  }
}

# Heroku-style addon map: one entry per backing service, e.g.
#
#   addons = {
#     mysql = { size = "medium" }
#     redis = { size = "mini" }
#   }
#
# `size` picks a preset plan (mini, small, medium, large — mini being the
# default); custom computational resources go in the addon-specific
# attribute instead (`scaling` for mysql ACU ranges, `node` for
# redis/memcached node type/count). Per-addon knobs beyond sizing live on
# the submodules, meant to be used directly for those cases.
variable "addons" {
  description = "Map of addon name => addon spec. Supported addons: mysql, redis, memcached."
  type = map(object({
    size = optional(string)
    # mysql only: custom Serverless v2 capacity range.
    scaling = optional(object({
      min_capacity             = number
      max_capacity             = number
      seconds_until_auto_pause = optional(number)
    }))
    # redis/memcached only: custom node type/count.
    node = optional(object({
      node_type = string
      num_nodes = optional(number, 1)
    }))
    # mysql only.
    database = optional(string)
    username = optional(string)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, spec in var.addons : contains(["mysql", "redis", "memcached"], k)])
    error_message = "Supported addons are: mysql, redis, memcached."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : spec.size == null || (spec.scaling == null && spec.node == null)])
    error_message = "Each addon may set either size or custom resources (scaling/node), not both."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : (spec.scaling == null && spec.database == null && spec.username == null) || k == "mysql"])
    error_message = "scaling, database and username only apply to the mysql addon."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : spec.node == null || k == "redis" || k == "memcached"])
    error_message = "node only applies to the redis and memcached addons."
  }
}

variable "vpc_id" {
  description = "VPC where the addons are created."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the addon subnet groups (private subnets spanning at least two AZs)."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach every addon (e.g. the cluster/node CIDR)."
  type        = list(string)
  default     = []
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach every addon."
  type        = list(string)
  default     = []
}

variable "production_grade" {
  description = "Production lifecycle for stateful addons: monitoring, deletion protection and final snapshot on MySQL. Disable for ephemeral environments (review apps, e2e)."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
