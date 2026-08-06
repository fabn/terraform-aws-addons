variable "name" {
  description = "Cluster identifier and base name for dependent resources (e.g. `myapp-staging-mysql`)."
  type        = string
}

variable "size" {
  description = "Heroku-style preset size (mini, small, medium, large) mapped to Serverless v2 ACU ranges; mini/small scale to zero. Set to null and pass `scaling` for custom capacity."
  type        = string
  default     = "mini"
  nullable    = true

  validation {
    condition     = var.size == null ? true : contains(["mini", "small", "medium", "large"], var.size)
    error_message = "size must be one of: mini, small, medium, large (or null when scaling is set)."
  }

  validation {
    condition     = (var.size == null) != (var.scaling == null)
    error_message = "Exactly one of size or scaling must be set: pass size = null when using custom scaling."
  }
}

variable "scaling" {
  description = "Custom Serverless v2 capacity range, alternative to `size`. min_capacity = 0 enables scale-to-zero (auto-pause after seconds_until_auto_pause)."
  type = object({
    min_capacity             = number
    max_capacity             = number
    seconds_until_auto_pause = optional(number)
  })
  default  = null
  nullable = true

  validation {
    condition     = var.scaling == null ? true : (var.scaling.seconds_until_auto_pause == null || var.scaling.min_capacity == 0)
    error_message = "seconds_until_auto_pause requires min_capacity = 0 (auto-pause only applies to clusters that scale to zero)."
  }
}

variable "database" {
  description = "Name of the database to create. Defaults to var.name with hyphens replaced by underscores."
  type        = string
  default     = null
  nullable    = true
}

variable "username" {
  description = "Master username the application connects with."
  type        = string
  default     = "app"
  # Callers (the root wrapper) may forward null to mean "use the default".
  nullable = false
}

variable "engine_version" {
  description = "Aurora MySQL engine version. Null lets AWS pick the default. Scale-to-zero requires >= 3.08."
  type        = string
  default     = null
  nullable    = true
}

variable "slow_query_log" {
  description = "Log queries slower than long_query_time and export them to CloudWatch Logs. Opt out for throwaway environments."
  type        = bool
  default     = true
  nullable    = false
}

variable "long_query_time" {
  description = "Threshold in seconds above which a query is logged as slow (fractions allowed)."
  type        = number
  default     = 2
  nullable    = false
}

variable "cluster_family" {
  description = "DB cluster parameter group family, must match engine_version. Only used when a cluster parameter group is created."
  type        = string
  default     = "aurora-mysql8.0"
  nullable    = false
}

# Engine settings the addon does not model. The slow query log is a first-class
# option because every stack wants it; anything else a caller needs goes here
# rather than growing a boolean per parameter.
#
# apply_method is the caller's call and it matters. A dynamic parameter takes
# effect immediately; a static one needs "pending-reboot" and, as the name says,
# a reboot before it applies. Passing a static parameter without it fails the
# apply rather than silently doing nothing, which is the better of the two.
#
# Two are worth knowing about before reaching for them. binlog_format turns the
# cluster into a binary log source, and the resulting activity stops a
# scale-to-zero cluster from ever pausing. gtid_mode and
# enforce_gtid_consistency are static, and are what a cluster needs in order to
# replicate from an external MySQL server.
variable "cluster_parameters" {
  description = "Extra DB cluster parameters, merged with the ones the addon manages itself."
  type = list(object({
    name         = string
    value        = string
    apply_method = optional(string)
  }))
  default  = []
  nullable = false
}

# Off by default, and that default is the addon contract rather than a
# preference: with the password generated here, `sensitive_env` can hand the
# application a ready DATABASE_URL. Turn this on and Terraform never sees the
# password — RDS generates it, keeps it in Secrets Manager and can rotate it —
# so DATABASE_URL and MYSQL_PASSWORD leave `sensitive_env`, and the secret's ARN
# is published instead.
#
# Worth it when the master user is an administrative account rather than the one
# the application connects as: nothing needs a URL composed from it, and the
# credential stops living in Terraform state.
variable "manage_master_user_password" {
  description = "Let RDS generate and store the master password in Secrets Manager instead of generating it here."
  type        = bool
  default     = false
  nullable    = false
}

# The Data API: an HTTPS endpoint for running SQL without a route into the VPC,
# and what the console's query editor is built on. Availability varies by region
# and engine version, so an apply is the only reliable check.
variable "enable_http_endpoint" {
  description = "Enable the RDS Data API on the cluster, allowing SQL over HTTPS from outside the VPC."
  type        = bool
  default     = false
  nullable    = false
}

variable "backup_retention_period" {
  description = "Days of automated backups to retain."
  type        = number
  default     = 7
  nullable    = false
}

variable "preferred_maintenance_window" {
  description = "Weekly UTC window when AWS applies system maintenance, format `ddd:hh24:mi-ddd:hh24:mi` (min 30 minutes). Defaults to a Monday-night slot so patches land off-peak; set null to let AWS pick a random window."
  type        = string
  default     = "mon:03:00-mon:04:00"
  nullable    = true

  validation {
    condition     = var.preferred_maintenance_window == null ? true : can(regex("^[A-Za-z]{3}:[0-9]{2}:[0-9]{2}-[A-Za-z]{3}:[0-9]{2}:[0-9]{2}$", var.preferred_maintenance_window))
    error_message = "preferred_maintenance_window must look like ddd:hh24:mi-ddd:hh24:mi (UTC), e.g. mon:03:00-mon:04:00."
  }
}

variable "preferred_backup_window" {
  description = "Daily UTC window when AWS takes automated backups, format `hh24:mi-hh24:mi` (min 30 minutes, must not overlap the maintenance window). Defaults to a nighttime slot before the maintenance window; set null to let AWS pick a random window."
  type        = string
  default     = "01:00-02:00"
  nullable    = true

  validation {
    condition     = var.preferred_backup_window == null ? true : can(regex("^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$", var.preferred_backup_window))
    error_message = "preferred_backup_window must look like hh24:mi-hh24:mi (UTC), e.g. 01:00-02:00."
  }
}

variable "replicas" {
  description = "Number of reader instances alongside the writer. Serverless v2 readers share the cluster's ACU range (size/scaling) but each instance scales independently within it; readers also serve as failover targets."
  type        = number
  default     = 0
  nullable    = false

  validation {
    condition     = var.replicas >= 0 && var.replicas <= 15
    error_message = "replicas must be between 0 and 15."
  }
}

variable "vpc_id" {
  description = "VPC where the cluster is created."
  type        = string
}

variable "subnet_ids" {
  description = "Subnets for the DB subnet group (private subnets spanning at least two AZs)."
  type        = list(string)
}

variable "allowed_cidr_blocks" {
  description = "CIDR blocks allowed to reach the cluster."
  type        = list(string)
  default     = []
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach the cluster."
  type        = list(string)
  default     = []
}

# Two features, two variables, because they do not share prerequisites. Enhanced
# monitoring collects OS-level metrics through an agent and creates an IAM role;
# Performance Insights is enabled on the instance and needs no role at all.
#
# One flag for both meant a caller whose principal cannot create IAM roles — a
# routine restriction for a role granted across accounts — had to give up query
# visibility for a permission only the OS metrics ever needed. Worse, the plan
# says nothing: it applies cleanly until it reaches the role.
variable "enhanced_monitoring" {
  description = "OS-level metrics through the RDS monitoring agent. Creates an IAM role, so the caller must be allowed to create one."
  type        = bool
  default     = true
  nullable    = false
}

variable "performance_insights" {
  description = "Query-level load analysis and database insights. Enabled on the instance, needs no IAM role."
  type        = bool
  default     = true
  nullable    = false
}

variable "deletion_protection" {
  description = "Protect the cluster from deletion. Disable for ephemeral environments."
  type        = bool
  default     = true
}

variable "skip_final_snapshot" {
  description = "Skip the final snapshot on destroy. Enable for ephemeral environments."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Additional tags applied to all resources."
  type        = map(string)
  default     = {}
}
