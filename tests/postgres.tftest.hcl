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
    condition     = output.sensitive_env.PGPASSWORD == random_password.admin.result
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
