# =============================================================================
# Redis Addon Tests
# =============================================================================

mock_provider "aws" {}
mock_provider "random" {}

run "default_size_is_mini" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name       = "myapp-redis"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.node.node_type == "cache.t4g.micro" && output.node.num_nodes == 1
    error_message = "mini should resolve to a single cache.t4g.micro node"
  }

  assert {
    condition     = startswith(output.env.REDIS_URL, "redis://") && endswith(output.env.REDIS_URL, ":6379")
    error_message = "REDIS_URL should be plaintext redis:// on the default port"
  }

  assert {
    condition     = length(output.sensitive_env) == 0
    error_message = "Redis addon runs without AUTH: sensitive_env must be empty"
  }
}

run "large_size_maps_to_m7g" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name       = "myapp-redis"
    size       = "large"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.node.node_type == "cache.m7g.large"
    error_message = "large should resolve to cache.m7g.large"
  }
}

run "custom_node_replaces_size" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name = "myapp-redis"
    size = null
    node = {
      node_type = "cache.r7g.xlarge"
      num_nodes = 2
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.node.node_type == "cache.r7g.xlarge" && output.node.num_nodes == 2
    error_message = "custom node should pass through untouched"
  }
}

run "transit_encryption_switches_scheme" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name                       = "myapp-redis"
    transit_encryption_enabled = true
    vpc_id                     = "vpc-12345"
    subnet_ids                 = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = startswith(output.env.REDIS_URL, "rediss://")
    error_message = "REDIS_URL should use rediss:// when transit encryption is on"
  }
}

run "rejects_size_and_node_together" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name = "myapp-redis"
    size = "small"
    node = {
      node_type = "cache.t4g.small"
    }
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.size]
}

run "rejects_multi_az_on_single_node" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name             = "myapp-redis"
    multi_az_enabled = true
    vpc_id           = "vpc-12345"
    subnet_ids       = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.multi_az_enabled]
}
