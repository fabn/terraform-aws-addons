# =============================================================================
# Memcached Addon Tests
# =============================================================================
# Node addresses are computed by AWS, so with mocked providers
# MEMCACHED_SERVER_URL cannot be asserted literally — the e2e suite covers the
# real endpoint; here the assertions target sizing and the contract shape.

mock_provider "aws" {}
mock_provider "random" {}

run "default_size_is_mini" {
  command = apply

  module {
    source = "./modules/memcached"
  }

  variables {
    name       = "myapp-memcached"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.node.node_type == "cache.t4g.micro" && output.node.num_nodes == 1
    error_message = "mini should resolve to a single cache.t4g.micro node"
  }

  assert {
    condition     = can(output.env.MEMCACHED_SERVER_URL)
    error_message = "env contract should expose MEMCACHED_SERVER_URL"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "Memcached addon has no SASL: sensitive_env must be empty"
  }
}

run "custom_node_replaces_size" {
  command = apply

  module {
    source = "./modules/memcached"
  }

  variables {
    name = "myapp-memcached"
    size = null
    node = {
      node_type = "cache.m7g.xlarge"
      num_nodes = 3
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.node.node_type == "cache.m7g.xlarge" && output.node.num_nodes == 3
    error_message = "custom node should pass through untouched"
  }
}

run "rejects_size_and_node_together" {
  command = plan

  module {
    source = "./modules/memcached"
  }

  variables {
    name = "myapp-memcached"
    size = "small"
    node = {
      node_type = "cache.t4g.small"
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.size]
}

run "maintenance_window_defaults_to_a_nighttime_slot" {
  command = apply

  module {
    source = "./modules/memcached"
  }

  variables {
    name       = "myapp-memcached"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.maintenance_window == "mon:03:00-mon:04:00"
    error_message = "maintenance should default to a Monday-night UTC window"
  }
}

run "rejects_malformed_maintenance_window" {
  command = plan

  module {
    source = "./modules/memcached"
  }

  variables {
    name               = "myapp-memcached"
    maintenance_window = "monday night"
    vpc_id             = "vpc-12345"
    subnet_ids         = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.maintenance_window]
}
