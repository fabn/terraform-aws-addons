variable "name" {
  description = "Stack name (e.g. `myapp-staging`). Addon resources are named `<name>-<addon>`; the default SQL database (mysql/postgres) is named after the stack."
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
# attribute instead (`scaling` for mysql/postgres ACU ranges,
# `instance_class` to leave Serverless v2 for provisioned instances, `node`
# for redis/memcached node type/count). Per-addon knobs beyond sizing live
# on the submodules, meant to be used directly for those cases.
variable "addons" {
  description = "Map of addon name => addon spec. Supported addons: mysql, postgres, redis, memcached."
  type = map(object({
    size = optional(string)
    # mysql/postgres/redis only: reader/replica instances alongside the writer/primary.
    replicas = optional(number)
    # mysql/postgres only: custom Serverless v2 capacity range.
    scaling = optional(object({
      min_capacity             = number
      max_capacity             = number
      seconds_until_auto_pause = optional(number)
    }))
    # mysql/postgres only: provisioned instance class instead of Serverless v2.
    instance_class = optional(string)
    # redis/memcached only: custom node type (+ node count on memcached).
    node = optional(object({
      node_type = string
      num_nodes = optional(number, 1)
    }))
    # mysql/postgres only.
    database       = optional(string)
    username       = optional(string)
    slow_query_log = optional(bool)
    # redis only.
    engine                   = optional(string)
    maxmemory_policy         = optional(string)
    snapshot_retention_limit = optional(number)
  }))
  default = {}

  validation {
    condition     = alltrue([for k, spec in var.addons : contains(["mysql", "postgres", "redis", "memcached"], k)])
    error_message = "Supported addons are: mysql, postgres, redis, memcached."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : spec.size == null || (spec.scaling == null && spec.node == null && spec.instance_class == null)])
    error_message = "Each addon may set either size or custom resources (scaling/instance_class/node), not both."
  }

  # Two ways to size a SQL addon beyond the presets, and they are alternatives:
  # an ACU range keeps Serverless v2, a class leaves it.
  validation {
    condition     = alltrue([for k, spec in var.addons : spec.scaling == null || spec.instance_class == null])
    error_message = "scaling and instance_class are alternatives: an ACU range keeps Serverless v2, a provisioned class replaces it."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : (spec.scaling == null && spec.instance_class == null && spec.database == null && spec.username == null && spec.slow_query_log == null) || contains(["mysql", "postgres"], k)])
    error_message = "scaling, instance_class, database, username and slow_query_log only apply to the mysql and postgres addons."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : spec.node == null || k == "redis" || k == "memcached"])
    error_message = "node only applies to the redis and memcached addons."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : spec.replicas == null || contains(["mysql", "postgres", "redis"], k)])
    error_message = "replicas only applies to the mysql, postgres and redis addons."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : (spec.engine == null && spec.maxmemory_policy == null && spec.snapshot_retention_limit == null) || k == "redis"])
    error_message = "engine, maxmemory_policy and snapshot_retention_limit only apply to the redis addon."
  }

  validation {
    condition     = alltrue([for k, spec in var.addons : contains(["redis", "valkey"], coalesce(spec.engine, "redis"))])
    error_message = "redis engine must be one of: redis, valkey."
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
  description = "Production lifecycle for stateful addons: monitoring, deletion protection and final snapshot on the mysql/postgres clusters. Disable for ephemeral environments (review apps, e2e)."
  type        = bool
  default     = true
}

variable "maintenance_window" {
  description = "Weekly UTC maintenance window (`ddd:hh24:mi-ddd:hh24:mi`) applied to every addon (Aurora clusters and ElastiCache). Defaults to a Monday-night slot so patches land off-peak; set null to let AWS pick a random window per addon."
  type        = string
  default     = "mon:03:00-mon:04:00"
  nullable    = true

  validation {
    condition     = var.maintenance_window == null ? true : can(regex("^[A-Za-z]{3}:[0-9]{2}:[0-9]{2}-[A-Za-z]{3}:[0-9]{2}:[0-9]{2}$", var.maintenance_window))
    error_message = "maintenance_window must look like ddd:hh24:mi-ddd:hh24:mi (UTC), e.g. mon:03:00-mon:04:00."
  }
}

variable "backup_window" {
  description = "Daily UTC backup window (`hh24:mi-hh24:mi`) applied to every addon that persists data: the mysql/postgres Aurora clusters (`preferred_backup_window`) and the redis RDB snapshot (`snapshot_window`, when persistence is on); must not overlap the maintenance window. Defaults to a nighttime slot before the maintenance window; set null to let AWS pick a random window."
  type        = string
  default     = "01:00-02:00"
  nullable    = true

  validation {
    condition     = var.backup_window == null ? true : can(regex("^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$", var.backup_window))
    error_message = "backup_window must look like hh24:mi-hh24:mi (UTC), e.g. 01:00-02:00."
  }
}

# Kept separate from production_grade even though both describe how careful the
# stack wants to be: production_grade is about what survives a destroy, this is
# about when a change lands. A production stack that deploys often may well want
# both true — modifications applied on the spot, because waiting for Monday
# night to see the change is worse than the interruption itself.
variable "apply_immediately" {
  description = "Apply addon modifications right away instead of deferring the disruptive ones (instance/node type, engine version) to `maintenance_window`. Applies to every addon; turn off where a brief interruption should wait for the window."
  type        = bool
  default     = true
  nullable    = false
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
