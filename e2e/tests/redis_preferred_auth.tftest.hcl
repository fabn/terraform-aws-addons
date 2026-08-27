# =============================================================================
# E2E probe: does a NEW replication group accept `preferred` plus an AUTH token?
# =============================================================================
# This is a question put to AWS, not a regression test.
#
# AWS states the requirement for AUTH as in-transit encryption being *enabled*
# — "AUTH can only be enabled for encryption in-transit enabled clusters" — and
# says nothing about the enforcement mode. Yet ModifyReplicationGroup was
# observed refusing a token while the mode was `preferred`:
#
#   InvalidParameterValue: The AUTH token modification is only supported when
#   encryption-in-transit is enabled
#
# Whether CreateReplicationGroup refuses the same combination decides whether
# the module may reject it in a variable validation, because a validation sees
# only the variable values — it cannot tell a create from a modify, and would
# block both.
#
# Reading the outcome:
#   passes  -> creation accepts the pair; a hard validation would be wrong, and
#              the restriction belongs in the docs as modify-only.
#   fails   -> AWS refuses it outright, and its error is the argument for
#              validating the combination away.
#
# Cheap next to the full suite: one mini ElastiCache, no Aurora.

run "network" {
  command = plan

  module {
    source = "./setup"
  }
}

run "creates_with_preferred_and_a_token" {
  command = apply

  module {
    source = "./../modules/redis"
  }

  variables {
    name = "aws-addons-e2e-pref-auth"
    size = "mini"

    transit_encryption_enabled = true
    transit_encryption_mode    = "preferred"
    auth_token_enabled         = true

    vpc_id              = run.network.vpc_id
    subnet_ids          = run.network.subnet_ids
    allowed_cidr_blocks = [run.network.cidr_block]

    tags = {
      Component = "e2e"
    }
  }

  assert {
    condition     = output.transit_encryption_mode == "preferred"
    error_message = "the group should report the mode it was created with"
  }

  assert {
    condition     = output.auth_token_enabled && startswith(nonsensitive(output.sensitive_env.REDIS_URL), "rediss://:")
    error_message = "an accepted token should publish a credentialed rediss:// URL in sensitive_env"
  }
}
