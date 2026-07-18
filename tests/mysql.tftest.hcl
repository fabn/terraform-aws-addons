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
    target = module.cluster.data.aws_iam_policy_document.enhanced_monitoring
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
}
mock_provider "random" {
  # The RDS instance identifier derives from random_pet: the auto-generated
  # mock string may start with a digit, which the AWS provider rejects.
  mock_resource "random_pet" {
    defaults = {
      id = "mock-pet"
    }
  }
}

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
    condition     = output.sensitive_env.MYSQL_PASSWORD == random_password.admin.result
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
