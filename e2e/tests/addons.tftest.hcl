# =============================================================================
# E2E: real AWS apply of the full addon stack
# =============================================================================
# No mocks: this provisions Aurora Serverless v2 + two ElastiCache clusters
# and asserts the env contract against real endpoints. The test framework
# destroys everything at the end of the run. Budget ~25 minutes (Aurora
# dominates).

run "provisions_the_stack" {
  command = apply

  assert {
    condition     = endswith(output.env.MYSQL_HOST, ".rds.amazonaws.com")
    error_message = "MYSQL_HOST should be a real RDS endpoint"
  }

  assert {
    condition     = !can(output.env.REDIS_URL) && startswith(nonsensitive(output.sensitive_env.REDIS_URL), "rediss://:") && endswith(nonsensitive(output.sensitive_env.REDIS_URL), ":6379")
    error_message = "the authenticated redis addon should publish a credentialed rediss:// URL in sensitive_env alone"
  }

  assert {
    condition     = endswith(output.env.MEMCACHED_SERVERS, ":11211") && !strcontains(output.env.MEMCACHED_SERVERS, "://")
    error_message = "MEMCACHED_SERVERS should be a scheme-less host:port node list"
  }

  assert {
    condition     = startswith(output.sensitive_env.DATABASE_URL, "mysql2://app:")
    error_message = "DATABASE_URL should embed the generated credentials"
  }
}
