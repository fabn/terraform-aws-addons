variable "name" {
  description = "Cluster identifier and base name for dependent resources (e.g. `myapp-staging-postgres`)."
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
  description = "Aurora PostgreSQL engine version. Null lets AWS pick the default. Scale-to-zero requires >= 15.4 (or 13.15 / 14.12 / 16.x)."
  type        = string
  default     = null
  nullable    = true
}

variable "slow_query_log" {
  description = "Log statements slower than long_query_time (via log_min_duration_statement) and export them to CloudWatch Logs. Opt out for throwaway environments."
  type        = bool
  default     = true
  nullable    = false
}

variable "long_query_time" {
  description = "Threshold in seconds above which a statement is logged as slow (fractions allowed); applied to log_min_duration_statement in milliseconds."
  type        = number
  default     = 2
  nullable    = false
}

variable "cluster_family" {
  description = "DB cluster parameter group family, must match engine_version. Only used when slow_query_log is enabled."
  type        = string
  default     = "aurora-postgresql16"
  nullable    = false
}

variable "backup_retention_period" {
  description = "Days of automated backups to retain."
  type        = number
  default     = 7
  nullable    = false
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

variable "monitoring_enabled" {
  description = "Enable enhanced monitoring and performance/database insights. Disable for ephemeral environments."
  type        = bool
  default     = true
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
