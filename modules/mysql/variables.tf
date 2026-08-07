variable "name" {
  description = "Cluster identifier and base name for dependent resources (e.g. `myapp-staging-mysql`)."
  type        = string
}

variable "size" {
  description = "Heroku-style preset size (mini, small, medium, large) mapped to Serverless v2 ACU ranges; mini/small scale to zero. Set to null and pass `scaling` for a custom ACU range, or `instance_class` for provisioned instances."
  type        = string
  default     = "mini"
  nullable    = true

  validation {
    condition     = var.size == null ? true : contains(["mini", "small", "medium", "large"], var.size)
    error_message = "size must be one of: mini, small, medium, large (or null when scaling is set)."
  }

  # Three ways to size a cluster and they are alternatives, not layers: two ACU
  # shapes (a preset or a custom range) and one provisioned class. Silently
  # ignoring the preset when a class is set would be the worst of the three.
  validation {
    condition     = length([for v in [var.size, var.scaling, var.instance_class] : true if v != null]) == 1
    error_message = "Exactly one of size, scaling or instance_class must be set: pass size = null when using custom scaling or a provisioned instance_class."
  }
}

# The escape hatch from Serverless v2, and deliberately shaped like `scaling`
# rather than like `size`: the caller names the class instead of picking from a
# tier list. Presets exist to spare a caller the ACU arithmetic, but the reason
# to leave Serverless v2 at all is a sizing review that already concluded which
# class wins — a `medium` that silently meant db.r7g.large would hide exactly
# the decision the caller came here to make.
#
# Serverless v2 stays the default and the right one. It bills a floor
# continuously and pays off when load varies or disappears; a steady working set
# with no idle periods gets more memory per euro from a fixed class, plus a
# buffer pool that does not resize underneath it. That is a post-launch call,
# made when there is data to answer it.
#
# Readers inherit the writer's class: `replicas` builds instances from one
# definition, and a cluster whose reader is a different size from its writer is
# a tuning problem rather than an addon-shaped one.
variable "instance_class" {
  description = "Provisioned Aurora instance class (e.g. `db.r7g.large`), applied to the writer and every reader, as an alternative to Serverless v2. Null (the default) keeps Serverless v2, sized by `size` or `scaling`."
  type        = string
  default     = null
  nullable    = true

  # db.serverless is not a class a caller picks here: it is what `size` and
  # `scaling` already mean, and naming it directly would produce a serverless
  # cluster with no capacity range — accepted by Terraform, rejected by AWS.
  validation {
    condition     = var.instance_class == null ? true : (startswith(var.instance_class, "db.") && var.instance_class != "db.serverless")
    error_message = "instance_class must be a provisioned Aurora class such as db.r7g.large; leave it null and use size/scaling for Serverless v2."
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
  description = "Let RDS generate and store the master password in Secrets Manager instead of generating it here. Not available when restoring, which keeps the source's credential."
  type        = bool
  default     = false
  nullable    = false

  # Not at creation, which is a narrower claim than impossible: the restore APIs
  # take no such parameter, so RDS would drop the flag and mint nothing. A later
  # modify-db-cluster does accept it, so rotating an inherited master onto a
  # managed secret is a real operation — just not one this addon performs, and
  # accepting the variable here would promise it at a point where it cannot
  # happen.
  validation {
    condition     = !var.manage_master_user_password || (var.clone_from == null && var.snapshot_identifier == null)
    error_message = "manage_master_user_password cannot be set while restoring: the restore APIs drop it, so the clone would keep the source's master password regardless (pass it as source_master_password to publish the credentials)."
  }
}

# Cloning: create the cluster as a copy-on-write clone of an existing one
# instead of an empty database. Aurora clones share the source's storage layer
# and only pay for the pages they change, so a clone is ready in minutes
# largely regardless of size — the difference between a per-PR database a
# developer waits for and one that is there when they need it.
#
# Two limits are worth knowing before cloning in a loop. AWS allows fifteen
# copy-on-write clones per source cluster; the sixteenth does not fail, it
# silently becomes a full copy — same API call, entirely different time and
# bill. And a clone's lineage is fixed at creation: pointing `clone_from` at a
# different source later replaces the cluster rather than re-cloning it.
#
# A clone is not a replica: no inbound replication means nothing keeps the
# writer busy, so the scale-to-zero sizes (the mini/small default) work here
# exactly as they do on an empty cluster.
#
# With one exception, and it is expensive. Replication *state* is not
# configuration — it lives in InnoDB tables in the `mysql` schema, on the volume
# the clone shares — so the parameter group carrying no gtid_mode does not save
# a clone whose source was itself an inbound binlog replica. That clone boots
# still pointing at its source's replication source and retries for roughly
# sixty days, which is enough to keep it pinned at its ceiling and stop it
# pausing entirely. mysql.rds_stop_replication() and
# mysql.rds_reset_external_source() clear it, over the Data API — which on a
# restored cluster is itself a second apply away.
variable "clone_from" {
  description = "Create the cluster as a clone of an existing one instead of empty. Defaults to a copy-on-write clone of the source's latest restorable time; a clone inherits the source's users, schemas and master password."
  type = object({
    source_cluster_identifier  = optional(string)
    source_cluster_resource_id = optional(string)
    restore_to_time            = optional(string)
    use_latest_restorable_time = optional(bool)
    restore_type               = optional(string, "copy-on-write")
  })
  default  = null
  nullable = true

  validation {
    condition     = var.clone_from == null ? true : (var.clone_from.source_cluster_identifier == null) != (var.clone_from.source_cluster_resource_id == null)
    error_message = "clone_from must set exactly one of source_cluster_identifier or source_cluster_resource_id."
  }

  # Restoring to a point in time and tracking the latest one are alternatives,
  # and AWS needs exactly one of them.
  validation {
    condition     = var.clone_from == null ? true : !(var.clone_from.restore_to_time != null && coalesce(var.clone_from.use_latest_restorable_time, false))
    error_message = "clone_from cannot set both restore_to_time and use_latest_restorable_time."
  }

  validation {
    condition     = var.clone_from == null ? true : (var.clone_from.restore_to_time != null || coalesce(var.clone_from.use_latest_restorable_time, true))
    error_message = "clone_from with use_latest_restorable_time = false must set restore_to_time."
  }

  # full-copy is a real restore: it reads the source's data instead of sharing
  # its pages, so it costs full storage and scales with database size.
  validation {
    condition     = var.clone_from == null ? true : contains(["copy-on-write", "full-copy"], coalesce(var.clone_from.restore_type, "copy-on-write"))
    error_message = "clone_from.restore_type must be one of: copy-on-write, full-copy."
  }
}

# The cheaper sibling of a clone, for restoring a fixed point rather than
# tracking the source. Same consequences for credentials and schemas; the
# difference is that a snapshot is a full restore, so it costs full storage and
# its duration scales with database size.
variable "snapshot_identifier" {
  description = "Create the cluster by restoring this DB cluster snapshot (name or ARN) instead of empty. Mutually exclusive with `clone_from`."
  type        = string
  default     = null
  nullable    = true

  validation {
    condition     = var.snapshot_identifier == null || var.clone_from == null
    error_message = "Set either clone_from or snapshot_identifier, not both."
  }
}

# Describes a credential, it does not set one — the distinction is the whole
# point of the name. A restored cluster's master password came off the source's
# storage volume, and `restore-db-cluster-to-point-in-time` has no master_*
# parameter at all: there is no API surface through which this module could
# change it. Anything that tried would have to be an `ALTER USER` against the
# running cluster, which is a job for whatever seeds the environment, not for
# Terraform.
#
# So this is the caller telling the addon a password it already knows, purely so
# `sensitive_env` can compose DATABASE_URL as it does for an empty cluster.
# Leave it out and `sensitive_env` is empty — the same honest answer the addon
# gives when RDS owns the password. Pass it wrong and nothing fails at apply:
# the cluster is fine and the published URL simply will not authenticate.
#
# The value goes into Terraform state, like every other credential the addon
# publishes. It must also be URL-safe: it lands in DATABASE_URL verbatim, and
# nothing here percent-encodes it (the passwords this module generates avoid
# special characters for the same reason).
variable "source_master_password" {
  description = "Master password the restored source already has, used only to compose `sensitive_env` — it is never applied to the cluster. Only valid with `clone_from`/`snapshot_identifier`; must be URL-safe. Omit to leave `sensitive_env` empty."
  type        = string
  sensitive   = true
  default     = null
  nullable    = true

  validation {
    condition     = var.source_master_password == null || var.clone_from != null || var.snapshot_identifier != null
    error_message = "source_master_password only applies when restoring (clone_from or snapshot_identifier); an empty cluster generates its own password."
  }
}

# The Data API: an HTTPS endpoint for running SQL without a route into the VPC,
# and what the console's query editor is built on. Availability varies by region
# and engine version, so an apply is the only reliable check.
#
# It cannot be turned on while restoring. Neither restore API carries the
# parameter (create-db-cluster and modify-db-cluster both do), so AWS drops it,
# reports HttpEndpointEnabled: False, and Terraform records false — no drift,
# just a second plan proposing false -> true. Anything a caller wants to do over
# the Data API right after cloning — creating the application accounts, say — is
# therefore gated behind that second apply.
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

# Immediate by default, because that is what makes an addon predictable: a
# change to the configuration lands on the next apply, and the plan is the whole
# story.
#
# The exception is a production cluster, where a handful of modifications —
# instance class, engine version, a static parameter needing a reboot — cost a
# brief interruption. Set this to false and RDS defers those to
# preferred_maintenance_window instead. Two things follow: non-disruptive
# changes still apply right away, and a deferred one stays pending on the AWS
# side until the window opens, so a later plan can look clean while the change
# has not landed yet.
variable "apply_immediately" {
  description = "Apply cluster modifications right away instead of deferring the disruptive ones to `preferred_maintenance_window`. Turn off on production clusters where a brief interruption should wait for the window."
  type        = bool
  default     = true
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

# Outbound, which a database usually needs none of — and which the module
# therefore leaves closed rather than opening by default. Terraform creates a
# security group with no egress at all, so nothing here reaches the internet
# unless it is asked for.
#
# It has to be asked for when the cluster replicates from a source outside the
# VPC: replication is *outbound*, the writer dials the source, and with no egress
# rule the connection simply never establishes. The failure gives nothing away —
# ingress is present, the plan is clean, and SHOW REPLICA STATUS reports
# "Can't connect to MySQL server" as if the source were down.
variable "egress_cidr_blocks" {
  description = "CIDR blocks the cluster may open connections to. Empty means no egress, which is right unless the cluster replicates from outside the VPC."
  type        = list(string)
  default     = []
  nullable    = false
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
