# =============================================================================
# Root Wrapper Tests
# =============================================================================
# The formation-style map: each entry deploys the matching addon submodule;
# env / sensitive_env merge every enabled addon's vars.

mock_provider "aws" {}
mock_provider "random" {}

run "deploys_declared_addons_and_merges_env" {
  command = apply

  variables {
    name             = "myapp-staging"
    production_grade = false
    vpc_id           = "vpc-12345"
    subnet_ids       = ["subnet-1", "subnet-2"]
    addons = {
      mysql = { size = "medium" }
      redis = { size = "mini" }
    }
  }

  assert {
    condition     = can(output.env.MYSQL_HOST) && can(output.env.REDIS_URL)
    error_message = "merged env should contain vars from every enabled addon"
  }

  assert {
    condition     = !can(output.env.MEMCACHED_SERVER_URL)
    error_message = "merged env should not contain vars from disabled addons"
  }

  assert {
    condition     = can(output.sensitive_env.DATABASE_URL)
    error_message = "merged sensitive_env should contain mysql credentials"
  }

  assert {
    condition     = output.env.MYSQL_DATABASE == "myapp_staging"
    error_message = "default mysql database should be named after the stack"
  }

  assert {
    condition     = output.mysql.scaling.min_capacity == 0.5 && output.mysql.scaling.max_capacity == 4
    error_message = "mysql size=medium should resolve to the 0.5-4 ACU range"
  }

  assert {
    condition     = output.redis.node_type == "cache.t4g.micro" && output.redis.replicas == 0
    error_message = "redis size=mini should resolve to a single cache.t4g.micro primary"
  }

  assert {
    condition     = output.memcached == null
    error_message = "disabled addons should output null details"
  }
}

run "defaults_to_mini_and_supports_custom_resources" {
  command = apply

  variables {
    name             = "myapp"
    production_grade = false
    vpc_id           = "vpc-12345"
    subnet_ids       = ["subnet-1", "subnet-2"]
    addons = {
      mysql = {
        scaling = {
          min_capacity             = 0
          max_capacity             = 16
          seconds_until_auto_pause = 600
        }
      }
      redis = {
        replicas                 = 1
        maxmemory_policy         = "allkeys-lru"
        snapshot_retention_limit = 0
      }
      memcached = {}
    }
  }

  assert {
    condition     = output.mysql.scaling.max_capacity == 16
    error_message = "custom mysql scaling should pass through the wrapper"
  }

  assert {
    condition     = output.redis.replicas == 1
    error_message = "redis cache posture (replicas, eviction, no persistence) should pass through the wrapper"
  }

  assert {
    condition     = output.memcached.node.node_type == "cache.t4g.micro"
    error_message = "an empty addon entry should default to the mini size"
  }
}

run "rejects_unknown_addon" {
  command = plan

  variables {
    name       = "myapp"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
    addons = {
      postgres = { size = "mini" }
    }
  }

  expect_failures = [var.addons]
}

run "rejects_size_and_custom_resources_together" {
  command = plan

  variables {
    name       = "myapp"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
    addons = {
      redis = {
        size = "small"
        node = { node_type = "cache.t4g.small" }
      }
    }
  }

  expect_failures = [var.addons]
}

run "rejects_mysql_attributes_on_cache_addons" {
  command = plan

  variables {
    name       = "myapp"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
    addons = {
      redis = { database = "nope" }
    }
  }

  expect_failures = [var.addons]
}
