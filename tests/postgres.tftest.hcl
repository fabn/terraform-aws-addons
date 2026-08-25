# =============================================================================
# PostgreSQL Addon Tests
# =============================================================================
# Sizes resolve to Serverless v2 ACU ranges; the env contract exposes the
# connection vars callers merge into the stack. Endpoints are mock values,
# so assertions target the shape of the vars, not concrete hostnames.

mock_provider "aws" {
  # The enhanced monitoring role embeds this document: the auto-generated
  # mock string would fail the provider's JSON policy validation.
  override_data {
    target = module.cluster.data.aws_iam_policy_document.monitoring_rds_assume_role
    values = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  # The enhanced monitoring policy ARN embeds the partition: the
  # auto-generated mock string would fail the provider's ARN validation.
  override_data {
    target = module.cluster.data.aws_partition.current
    values = {
      partition = "aws"
    }
  }

  # The cluster references the monitoring role by ARN: the auto-generated
  # mock string would fail the provider's ARN validation.
  mock_resource "aws_iam_role" {
    defaults = {
      arn = "arn:aws:iam::123456789012:role/mock-monitoring"
    }
  }
}
mock_provider "random" {}

run "default_size_is_mini" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-staging-postgres"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.scaling.min_capacity == 0 && output.scaling.max_capacity == 1
    error_message = "mini should scale between 0 and 1 ACU"
  }

  assert {
    condition     = output.scaling.seconds_until_auto_pause == 300
    error_message = "mini should auto-pause after 5 minutes"
  }

  assert {
    condition     = output.env.PGPORT == "5432" && output.env.PGUSER == "app"
    error_message = "env contract should expose default port and username"
  }

  assert {
    condition     = output.env.PGDATABASE == "myapp_staging_postgres"
    error_message = "default database name should derive from name with underscores"
  }

  assert {
    condition     = startswith(output.sensitive_env.DATABASE_URL, "postgresql://app:")
    error_message = "DATABASE_URL should use the postgresql scheme and embed the username"
  }

  assert {
    condition     = endswith(output.sensitive_env.DATABASE_URL, ":5432/myapp_staging_postgres")
    error_message = "DATABASE_URL should target port and database"
  }

  assert {
    condition     = output.sensitive_env.PGPASSWORD == one(random_password.admin[*].result)
    error_message = "PGPASSWORD should be the generated password"
  }
}

run "medium_size_keeps_warm_floor" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    size       = "medium"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.scaling.min_capacity == 0.5 && output.scaling.max_capacity == 4
    error_message = "medium should scale between 0.5 and 4 ACU"
  }

  assert {
    condition     = output.scaling.seconds_until_auto_pause == null
    error_message = "medium should not auto-pause (warm floor)"
  }
}

run "custom_scaling_replaces_size" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    size = null
    scaling = {
      min_capacity             = 0
      max_capacity             = 16
      seconds_until_auto_pause = 600
    }
    database   = "myapp"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.scaling.max_capacity == 16 && output.scaling.seconds_until_auto_pause == 600
    error_message = "custom scaling should pass through untouched"
  }

  assert {
    condition     = output.env.PGDATABASE == "myapp"
    error_message = "explicit database name should win over the derived one"
  }
}

run "slow_query_log_opt_out" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name           = "myapp-postgres"
    slow_query_log = false
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = can(output.env.PGHOST)
    error_message = "opting out of the slow query log should not create the parameter group path"
  }
}

run "rejects_size_and_scaling_together" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    size = "small"
    scaling = {
      min_capacity = 0
      max_capacity = 2
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.size]
}

run "rejects_unknown_size" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    size       = "gigantic"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.size]
}

run "rejects_auto_pause_with_warm_floor" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    size = null
    scaling = {
      min_capacity             = 1
      max_capacity             = 8
      seconds_until_auto_pause = 300
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.scaling]
}

run "maintenance_windows_default_to_a_nighttime_slot" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.preferred_maintenance_window == "mon:03:00-mon:04:00"
    error_message = "maintenance should default to a Monday-night UTC window"
  }

  assert {
    condition     = output.preferred_backup_window == "01:00-02:00"
    error_message = "backups should default to a nighttime UTC window that precedes maintenance"
  }
}

run "maintenance_windows_can_be_overridden_or_disabled" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name                         = "myapp-postgres"
    preferred_maintenance_window = "sun:23:00-mon:00:00"
    preferred_backup_window      = null
    vpc_id                       = "vpc-12345"
    subnet_ids                   = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.preferred_maintenance_window == "sun:23:00-mon:00:00"
    error_message = "an explicit maintenance window should pass through untouched"
  }

  assert {
    condition     = output.preferred_backup_window == null
    error_message = "a null backup window should pass through (AWS picks a random one)"
  }
}

run "rejects_malformed_maintenance_window" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name                         = "myapp-postgres"
    preferred_maintenance_window = "monday night"
    vpc_id                       = "vpc-12345"
    subnet_ids                   = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.preferred_maintenance_window]
}

run "rejects_malformed_backup_window" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name                    = "myapp-postgres"
    preferred_backup_window = "mon:01:00-mon:02:00"
    vpc_id                  = "vpc-12345"
    subnet_ids              = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.preferred_backup_window]
}

run "applies_modifications_immediately_by_default" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.apply_immediately
    error_message = "an addon should apply changes on the next apply unless told otherwise"
  }
}

run "modifications_can_be_deferred_to_the_maintenance_window" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name              = "myapp-postgres"
    apply_immediately = false
    vpc_id            = "vpc-12345"
    subnet_ids        = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = !output.apply_immediately
    error_message = "disruptive changes should be deferrable to the maintenance window"
  }

  # Deferring is only meaningful against a known window, which stays the
  # addon's own default rather than something the caller has to remember.
  assert {
    condition     = output.preferred_maintenance_window == "mon:03:00-mon:04:00"
    error_message = "deferred changes should land in the addon's off-peak maintenance window"
  }
}

run "clone_defaults_to_a_copy_on_write_clone_of_the_latest_time" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    database   = "prod_app"
    username   = "source_admin"
    clone_from = { source_cluster_identifier = "prod-postgres" }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.restored_from.mode == "copy-on-write" && output.restored_from.source == "prod-postgres"
    error_message = "clone_from should default to a copy-on-write clone of the named source"
  }

  # The clone inherits the source's credentials, so there is nothing to
  # generate and nothing to publish.
  assert {
    condition     = length(random_password.admin) == 0
    error_message = "no password should be generated for a cluster that inherits the source's"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "sensitive_env should be empty when the source's password was not supplied"
  }

  # The plaintext half still stands: the caller names the source's user and
  # database, and the app needs both to connect.
  assert {
    condition     = output.env.PGUSER == "source_admin" && output.env.PGDATABASE == "prod_app"
    error_message = "the plaintext env contract should describe the inherited user and database"
  }

  # A clone has no inbound replication, so the scale-to-zero default applies
  # here exactly as it does to an empty cluster.
  assert {
    condition     = output.scaling.min_capacity == 0
    error_message = "a clone should still default to a scale-to-zero size"
  }
}

run "clone_with_the_source_password_completes_the_contract" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name                   = "myapp-postgres"
    database               = "prod_app"
    username               = "source_admin"
    source_master_password = "sourcepassword"
    clone_from             = { source_cluster_identifier = "prod-postgres" }
    vpc_id                 = "vpc-12345"
    subnet_ids             = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.sensitive_env.PGPASSWORD == "sourcepassword"
    error_message = "a supplied source password should be published like a generated one"
  }

  assert {
    condition     = startswith(output.sensitive_env.DATABASE_URL, "postgresql://source_admin:sourcepassword@")
    error_message = "DATABASE_URL should compose from the source's credentials"
  }

  assert {
    condition     = endswith(output.sensitive_env.DATABASE_URL, "/prod_app")
    error_message = "DATABASE_URL should point at the inherited database"
  }
}

run "clone_can_pin_a_point_in_time" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    clone_from = {
      source_cluster_resource_id = "cluster-ABCDEF123456"
      restore_to_time            = "2026-08-05T12:00:00Z"
      restore_type               = "full-copy"
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.restored_from.mode == "full-copy" && output.restored_from.source == "cluster-ABCDEF123456"
    error_message = "a pinned full-copy restore should be reported as such"
  }
}

run "snapshot_restore_is_reported_as_its_own_mode" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name                = "myapp-postgres"
    snapshot_identifier = "prod-postgres-2026-08-05"
    vpc_id              = "vpc-12345"
    subnet_ids          = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.restored_from.mode == "snapshot" && output.restored_from.source == "prod-postgres-2026-08-05"
    error_message = "a snapshot restore should be reported as a snapshot"
  }

  assert {
    condition     = length(random_password.admin) == 0
    error_message = "a snapshot restore inherits the source's password too"
  }
}

run "an_empty_cluster_reports_no_lineage" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.restored_from == null
    error_message = "a cluster created empty should report no restore lineage"
  }

  assert {
    condition     = length(output.sensitive_env) == 2
    error_message = "the default contract should be unaffected by the restore options"
  }
}

run "rejects_clone_and_snapshot_together" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name                = "myapp-postgres"
    clone_from          = { source_cluster_identifier = "prod-postgres" }
    snapshot_identifier = "prod-postgres-2026-08-05"
    vpc_id              = "vpc-12345"
    subnet_ids          = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.snapshot_identifier]
}

run "rejects_a_clone_without_exactly_one_source" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    clone_from = {
      source_cluster_identifier  = "prod-postgres"
      source_cluster_resource_id = "cluster-ABCDEF123456"
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.clone_from]
}

run "rejects_a_clone_with_no_source_at_all" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    clone_from = { restore_to_time = "2026-08-05T12:00:00Z" }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.clone_from]
}

run "rejects_both_ways_of_choosing_a_restore_point" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    clone_from = {
      source_cluster_identifier  = "prod-postgres"
      restore_to_time            = "2026-08-05T12:00:00Z"
      use_latest_restorable_time = true
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.clone_from]
}

run "rejects_neither_way_of_choosing_a_restore_point" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    clone_from = {
      source_cluster_identifier  = "prod-postgres"
      use_latest_restorable_time = false
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.clone_from]
}

run "rejects_an_unknown_restore_type" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    clone_from = {
      source_cluster_identifier = "prod-postgres"
      restore_type              = "copy-on-read"
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.clone_from]
}

run "rejects_a_source_password_on_an_empty_cluster" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name                   = "myapp-postgres"
    source_master_password = "sourcepassword"
    vpc_id                 = "vpc-12345"
    subnet_ids             = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.source_master_password]
}

run "postgres_publishes_the_cluster_arn" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  # The Data API and IAM policies want the ARN, and reassembling it from
  # identifier + region + account is the caller's problem this output removes.
  assert {
    condition     = output.cluster_arn != null
    error_message = "the cluster ARN should be published rather than left to be rebuilt"
  }
}

run "provisioned_class_replaces_the_acu_range" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name           = "myapp-postgres"
    size           = null
    instance_class = "db.r7g.large"
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.instance_class == "db.r7g.large"
    error_message = "a named class should reach the writer instead of db.serverless"
  }

  # A provisioned cluster has no ACU range at all — passing one alongside a
  # fixed class is what AWS rejects.
  assert {
    condition     = output.scaling == null
    error_message = "a provisioned cluster should carry no serverless scaling configuration"
  }
}

run "serverless_stays_the_default" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.instance_class == "db.serverless"
    error_message = "nothing should change for a caller who never mentions instance_class"
  }

  assert {
    condition     = output.scaling.min_capacity == 0 && output.scaling.max_capacity == 1
    error_message = "the mini preset should still resolve to its ACU range"
  }
}

run "provisioned_class_applies_to_readers_too" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name           = "myapp-postgres"
    size           = null
    instance_class = "db.r7g.xlarge"
    replicas       = 2
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  # Readers inherit the writer's class: the instances map is built from one
  # definition, so a mixed-class cluster is not something this addon expresses.
  assert {
    condition     = output.instance_class == "db.r7g.xlarge"
    error_message = "every instance should share the class, readers included"
  }
}

run "rejects_a_preset_alongside_a_provisioned_class" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name           = "myapp-postgres"
    size           = "medium"
    instance_class = "db.r7g.large"
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  # Silently ignoring the preset would be the worst of the three outcomes.
  expect_failures = [var.size]
}

run "an_acu_range_survives_a_provisioned_default_class" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    size = null
    scaling = {
      min_capacity = 0
      max_capacity = 4
    }
    instance_class = "db.r7g.large"
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  # AWS keeps a capacity range it was once given even after the last serverless
  # instance leaves, so a cluster converted to provisioned throughout has to go
  # on stating it or the diff never applies.
  assert {
    condition     = output.scaling.max_capacity == 4
    error_message = "the cluster should keep the ACU range the caller asked for"
  }

  assert {
    condition     = output.instance_class == "db.r7g.large"
    error_message = "the default class should still be the provisioned one"
  }
}

run "one_instance_can_leave_the_default_class" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    replicas   = 1
    instances  = { "2" = { instance_class = "db.t4g.medium", promotion_tier = 0 } }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  # The shape AWS prescribes for converting a running cluster: the reader takes
  # the target class and a failover onto it makes it the writer.
  assert {
    condition     = output.instances["1"].instance_class == "db.serverless"
    error_message = "the instance that was not named should keep the cluster default"
  }

  assert {
    condition     = output.instances["2"].instance_class == "db.t4g.medium"
    error_message = "a named instance should take its own class"
  }

  assert {
    condition     = output.instances["2"].promotion_tier == 0
    error_message = "a named instance should take its own promotion tier"
  }

  assert {
    condition     = output.scaling.max_capacity == 1
    error_message = "the cluster should keep the ACU range its serverless instance runs on"
  }
}

run "a_serverless_instance_can_sit_beside_a_provisioned_default" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name = "myapp-postgres"
    size = null
    scaling = {
      min_capacity = 0
      max_capacity = 4
    }
    instance_class = "db.r7g.large"
    replicas       = 1
    instances      = { "2" = { instance_class = "db.serverless", promotion_tier = 15 } }
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  # The reverse direction: tier 15 keeps the reader scaling on its own workload
  # instead of tracking the provisioned writer's capacity.
  assert {
    condition     = output.instances["1"].instance_class == "db.r7g.large" && output.instances["2"].instance_class == "db.serverless"
    error_message = "a mixed cluster should be expressible in both directions"
  }
}

run "instances_defaults_to_a_uniform_cluster" {
  command = apply

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    replicas   = 2
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = length([for k, v in output.instances : k if v.instance_class != "db.serverless"]) == 0
    error_message = "nothing should change for a caller who never mentions instances"
  }

  assert {
    condition     = length([for k, v in output.instances : k if v.promotion_tier != null]) == 0
    error_message = "an unmentioned instance should leave its promotion tier to AWS"
  }
}

run "rejects_an_override_on_an_instance_the_cluster_does_not_have" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    instances  = { "2" = { instance_class = "db.t4g.medium" } }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  # replicas is 0, so there is no instance "2" and the override would be
  # ignored in silence.
  expect_failures = [var.instances]
}

run "rejects_a_serverless_instance_on_a_cluster_with_no_acu_range" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name           = "myapp-postgres"
    size           = null
    instance_class = "db.r7g.large"
    replicas       = 1
    instances      = { "2" = { instance_class = "db.serverless" } }
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.instances]
}

run "rejects_a_promotion_tier_that_is_not_one" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    replicas   = 1
    instances  = { "2" = { promotion_tier = 16 } }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.instances]
}

run "rejects_sizing_a_cluster_no_way_at_all" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name       = "myapp-postgres"
    size       = null
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.size]
}

run "rejects_naming_the_serverless_class_directly" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name           = "myapp-postgres"
    size           = null
    instance_class = "db.serverless"
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  # It would build a serverless cluster with no capacity range: accepted here,
  # rejected by AWS.
  expect_failures = [var.instance_class]
}

run "rejects_a_class_that_is_not_one" {
  command = plan

  module {
    source = "./modules/postgres"
  }

  variables {
    name           = "myapp-postgres"
    size           = null
    instance_class = "r7g.large"
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.instance_class]
}
