# =============================================================================
# Redis Addon Tests
# =============================================================================

mock_provider "aws" {}

# The AWS provider validates the auth token's length and alphabet (16-128
# characters, no @, " or /) even against a mocked provider, and a generated mock
# value is too short to pass.
mock_provider "random" {
  mock_resource "random_password" {
    defaults = {
      result = "mockauthtokenmockauthtokenmockauthtoken"
    }
  }
}

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
    condition     = output.node_type == "cache.t4g.micro" && output.replicas == 0
    error_message = "mini should resolve to a single cache.t4g.micro primary"
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

run "default_engine_is_redis" {
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
    condition     = output.engine == "redis" && output.parameter_group_family == "redis7"
    error_message = "redis should be the default engine on the redis7 parameter group family"
  }
}

run "valkey_engine_switches_family" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name       = "myapp-redis"
    engine     = "valkey"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.engine == "valkey" && output.parameter_group_family == "valkey8"
    error_message = "valkey should default to the valkey8 parameter group family"
  }

  assert {
    condition     = startswith(output.env.REDIS_URL, "redis://")
    error_message = "valkey keeps the redis protocol: REDIS_URL is unchanged"
  }
}

run "engine_defaults_can_be_overridden" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name                   = "myapp-redis"
    engine                 = "valkey"
    engine_version         = "7.2"
    parameter_group_family = "valkey7"
    vpc_id                 = "vpc-12345"
    subnet_ids             = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.parameter_group_family == "valkey7"
    error_message = "an explicit parameter_group_family should win over the engine default"
  }
}

run "rejects_unknown_engine" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name       = "myapp-redis"
    engine     = "keydb"
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.engine]
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
    condition     = output.node_type == "cache.m7g.large"
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
    }
    replicas   = 2
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.node_type == "cache.r7g.xlarge" && output.replicas == 2
    error_message = "custom node and replicas should pass through untouched"
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

run "auth_token_moves_the_url_into_sensitive_env" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name                       = "myapp-redis"
    transit_encryption_enabled = true
    auth_token_enabled         = true
    vpc_id                     = "vpc-12345"
    subnet_ids                 = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = length(output.env) == 0
    error_message = "a URL carrying an auth token is a credential: env must not publish it"
  }

  assert {
    condition     = startswith(nonsensitive(output.sensitive_env.REDIS_URL), "rediss://:") && endswith(nonsensitive(output.sensitive_env.REDIS_URL), ":6379")
    error_message = "sensitive_env should carry the credentialed rediss:// URL"
  }

  assert {
    condition     = nonsensitive(output.sensitive_env.REDIS_AUTH_TOKEN) == nonsensitive(output.auth_token)
    error_message = "the token published in sensitive_env should be the one the addon generated"
  }

  assert {
    condition     = output.auth_token_enabled && output.transit_encryption_enabled
    error_message = "the addon should report the posture it was given"
  }
}

run "no_auth_token_leaves_the_url_in_env" {
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
    condition     = output.env.REDIS_URL == "rediss://${output.host}:6379" && length(output.sensitive_env) == 0
    error_message = "TLS alone adds no credential: REDIS_URL stays plaintext config"
  }

  assert {
    condition     = output.auth_token == null
    error_message = "no token should be generated unless one is asked for"
  }
}

run "transit_encryption_mode_opens_the_migration_window" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name                       = "myapp-redis"
    transit_encryption_enabled = true
    transit_encryption_mode    = "preferred"
    auth_token_enabled         = true
    vpc_id                     = "vpc-12345"
    subnet_ids                 = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.transit_encryption_mode == "preferred"
    error_message = "preferred should pass through, so clients can be migrated before TLS is enforced"
  }

  # The token is what the mode is a migration towards, and it applies either way:
  # `preferred` relaxes the transport, not the credential.
  assert {
    condition     = startswith(nonsensitive(output.sensitive_env.REDIS_URL), "rediss://:")
    error_message = "the credentialed URL should not depend on the enforcement mode"
  }
}

run "mode_defaults_to_the_aws_choice" {
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
    condition     = output.transit_encryption_mode == null
    error_message = "an unset mode should stay null rather than being decided here"
  }
}

run "rejects_an_unknown_transit_encryption_mode" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name                       = "myapp-redis"
    transit_encryption_enabled = true
    transit_encryption_mode    = "optional"
    vpc_id                     = "vpc-12345"
    subnet_ids                 = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.transit_encryption_mode]
}

run "rejects_a_transit_encryption_mode_without_transit_encryption" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name                    = "myapp-redis"
    transit_encryption_mode = "required"
    vpc_id                  = "vpc-12345"
    subnet_ids              = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.transit_encryption_mode]
}

run "rejects_an_auth_token_without_transit_encryption" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name               = "myapp-redis"
    auth_token_enabled = true
    vpc_id             = "vpc-12345"
    subnet_ids         = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.auth_token_enabled]
}

run "cache_posture" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name                     = "myapp-redis"
    maxmemory_policy         = "allkeys-lru"
    snapshot_retention_limit = 0
    vpc_id                   = "vpc-12345"
    subnet_ids               = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = can(output.env.REDIS_URL)
    error_message = "cache posture (eviction on, persistence off) should be accepted"
  }
}

run "slow_log_goes_to_cloudwatch_by_default" {
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
    condition     = output.log_delivery_configuration["slow-log"].destination_type == "cloudwatch-logs"
    error_message = "the slow log should be delivered to CloudWatch Logs by default"
  }

  assert {
    condition     = output.slow_log_group_name == "/aws/elasticache/myapp-redis"
    error_message = "the default slow log should land in a log group named after the replication group"
  }
}

run "slow_log_opt_out" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name       = "myapp-redis"
    slow_log   = false
    vpc_id     = "vpc-12345"
    subnet_ids = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = length(output.log_delivery_configuration) == 0
    error_message = "opting out should leave the replication group with no log delivery configuration at all"
  }

  assert {
    condition     = output.slow_log_group_name == null
    error_message = "opting out should create no CloudWatch log group"
  }
}

run "rejects_invalid_eviction_policy" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name             = "myapp-redis"
    maxmemory_policy = "keep-everything"
    vpc_id           = "vpc-12345"
    subnet_ids       = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.maxmemory_policy]
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

run "rejects_multi_az_without_replicas" {
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

run "maintenance_window_defaults_to_a_nighttime_slot" {
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
    condition     = output.maintenance_window == "mon:03:00-mon:04:00"
    error_message = "maintenance should default to a Monday-night UTC window"
  }

  assert {
    condition     = output.snapshot_window == "01:00-02:00"
    error_message = "snapshots should default to a nighttime UTC window that precedes maintenance"
  }
}

run "snapshot_window_is_dropped_when_persistence_is_off" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name                     = "myapp-redis"
    snapshot_retention_limit = 0
    vpc_id                   = "vpc-12345"
    subnet_ids               = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.snapshot_window == null
    error_message = "with persistence off there are no snapshots to schedule, so the window should be null"
  }
}

run "maintenance_window_can_be_overridden_or_disabled" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name               = "myapp-redis"
    maintenance_window = null
    snapshot_window    = "05:00-06:00"
    vpc_id             = "vpc-12345"
    subnet_ids         = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = output.maintenance_window == null
    error_message = "a null maintenance window should pass through (AWS picks a random one)"
  }

  assert {
    condition     = output.snapshot_window == "05:00-06:00"
    error_message = "an explicit snapshot window should pass through untouched"
  }
}

run "rejects_malformed_snapshot_window" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name            = "myapp-redis"
    snapshot_window = "mon:01:00-mon:02:00"
    vpc_id          = "vpc-12345"
    subnet_ids      = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.snapshot_window]
}

run "rejects_malformed_maintenance_window" {
  command = plan

  module {
    source = "./modules/redis"
  }

  variables {
    name               = "myapp-redis"
    maintenance_window = "monday night"
    vpc_id             = "vpc-12345"
    subnet_ids         = ["subnet-1", "subnet-2"]
  }

  expect_failures = [var.maintenance_window]
}

run "applies_modifications_immediately_by_default" {
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
    condition     = output.apply_immediately
    error_message = "an addon should apply changes on the next apply unless told otherwise"
  }
}

run "modifications_can_be_deferred_to_the_maintenance_window" {
  command = apply

  module {
    source = "./modules/redis"
  }

  variables {
    name              = "myapp-redis"
    apply_immediately = false
    vpc_id            = "vpc-12345"
    subnet_ids        = ["subnet-1", "subnet-2"]
  }

  assert {
    condition     = !output.apply_immediately
    error_message = "a failover-inducing change should be deferrable to the maintenance window"
  }

  # Deferring is only meaningful against a known window, which stays the
  # addon's own default rather than something the caller has to remember.
  assert {
    condition     = output.maintenance_window == "mon:03:00-mon:04:00"
    error_message = "deferred changes should land in the addon's off-peak maintenance window"
  }
}
