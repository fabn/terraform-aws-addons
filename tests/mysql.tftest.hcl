# =============================================================================
# MySQL Addon Tests
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
    source = "./modules/mysql"
  }

  variables {
    name       = "myapp-staging-mysql"
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
    condition     = output.env.MYSQL_PORT == "3306" && output.env.MYSQL_USER == "app"
    error_message = "env contract should expose default port and username"
  }

  assert {
    condition     = output.env.MYSQL_DATABASE == "myapp_staging_mysql"
    error_message = "default database name should derive from name with underscores"
  }

  assert {
    condition     = startswith(output.sensitive_env.DATABASE_URL, "mysql2://app:")
    error_message = "DATABASE_URL should use the mysql2 scheme and embed the username"
  }

  assert {
    condition     = endswith(output.sensitive_env.DATABASE_URL, ":3306/myapp_staging_mysql")
    error_message = "DATABASE_URL should target port and database"
  }

  assert {
    condition     = output.sensitive_env.MYSQL_PASSWORD == one(random_password.admin[*].result)
    error_message = "MYSQL_PASSWORD should be the generated password"
  }
}

run "medium_size_keeps_warm_floor" {
  command = apply

  module {
    source = "./modules/mysql"
  }

  variables {
    name       = "myapp-mysql"
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
    source = "./modules/mysql"
  }

  variables {
    name = "myapp-mysql"
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
    condition     = output.env.MYSQL_DATABASE == "myapp"
    error_message = "explicit database name should win over the derived one"
  }
}

run "slow_query_log_opt_out" {
  command = apply

  module {
    source = "./modules/mysql"
  }

  variables {
    name           = "myapp-mysql"
    slow_query_log = false
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = length(output.cluster_parameters) == 0
    error_message = "opting out of the slow query log with no extra parameters should leave the group uncreated"
  }
}

run "rejects_size_and_scaling_together" {
  command = plan

  module {
    source = "./modules/mysql"
  }

  variables {
    name = "myapp-mysql"
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
    source = "./modules/mysql"
  }

  variables {
    name       = "myapp-mysql"
    size       = "gigantic"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.size]
}

run "rejects_auto_pause_with_warm_floor" {
  command = plan

  module {
    source = "./modules/mysql"
  }

  variables {
    name = "myapp-mysql"
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
    source = "./modules/mysql"
  }

  variables {
    name       = "myapp-mysql"
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
    source = "./modules/mysql"
  }

  variables {
    name                         = "myapp-mysql"
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
    source = "./modules/mysql"
  }

  variables {
    name                         = "myapp-mysql"
    preferred_maintenance_window = "monday night"
    vpc_id                       = "vpc-12345"
    subnet_ids                   = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.preferred_maintenance_window]
}

run "rejects_malformed_backup_window" {
  command = plan

  module {
    source = "./modules/mysql"
  }

  variables {
    name                    = "myapp-mysql"
    preferred_backup_window = "mon:01:00-mon:02:00"
    vpc_id                  = "vpc-12345"
    subnet_ids              = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.preferred_backup_window]
}

run "extra_cluster_parameters_merge_with_the_managed_ones" {
  command = apply

  module {
    source = "./modules/mysql"
  }

  variables {
    name       = "myapp-mysql"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
    cluster_parameters = [
      { name = "gtid_mode", value = "ON", apply_method = "pending-reboot" },
      { name = "enforce_gtid_consistency", value = "ON", apply_method = "pending-reboot" },
    ]
  }

  assert {
    condition     = length(output.cluster_parameters) == 5
    error_message = "extra parameters should be appended to the three the slow query log contributes"
  }

  assert {
    condition = anytrue([
      for p in output.cluster_parameters :
      p.name == "gtid_mode" && p.value == "ON" && p.apply_method == "pending-reboot"
    ])
    error_message = "a caller's parameter should keep its apply_method"
  }
}

run "extra_cluster_parameters_stand_alone" {
  command = apply

  module {
    source = "./modules/mysql"
  }

  variables {
    name           = "myapp-mysql"
    slow_query_log = false
    vpc_id         = "vpc-12345"
    subnet_ids     = ["subnet-1", "subnet-2"]
    cluster_parameters = [
      { name = "gtid_mode", value = "ON", apply_method = "pending-reboot" },
    ]
  }

  assert {
    condition     = length(output.cluster_parameters) == 1
    error_message = "the group should still be created for a caller's parameters with the slow query log off"
  }
}

run "managed_master_password_withholds_the_credentials" {
  command = apply

  module {
    source = "./modules/mysql"
  }

  variables {
    name                        = "myapp-mysql"
    vpc_id                      = "vpc-12345"
    subnet_ids                  = ["subnet-1", "subnet-2"]
    manage_master_user_password = true
  }

  # Not a degraded contract but an accurate one: RDS holds the password, so
  # there is nothing to compose a URL from.
  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "sensitive_env should be empty when RDS owns the master password"
  }

  assert {
    condition     = length(random_password.admin) == 0
    error_message = "no password should be generated when RDS owns it"
  }

  assert {
    condition     = output.env.MYSQL_USER == "app"
    error_message = "the plaintext env contract should be unaffected"
  }
}

run "performance_insights_survives_without_the_monitoring_role" {
  command = apply

  module {
    source = "./modules/mysql"
  }

  variables {
    name                = "myapp-mysql"
    vpc_id              = "vpc-12345"
    subnet_ids          = ["subnet-1", "subnet-2"]
    enhanced_monitoring = false
  }

  # The point of the split: a caller who cannot create an IAM role keeps query
  # visibility instead of losing it to a permission only the OS metrics need.
  assert {
    condition     = !output.monitoring.enhanced_monitoring
    error_message = "turning off enhanced monitoring should create no IAM role"
  }

  assert {
    condition     = output.monitoring.performance_insights
    error_message = "Performance Insights should survive enhanced monitoring being off"
  }
}

run "applies_modifications_immediately_by_default" {
  command = apply

  module {
    source = "./modules/mysql"
  }

  variables {
    name       = "myapp-mysql"
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
    source = "./modules/mysql"
  }

  variables {
    name              = "myapp-mysql"
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
