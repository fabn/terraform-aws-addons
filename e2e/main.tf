# E2E harness: provisions the full addon stack (mini sizes, ephemeral
# lifecycle) in the account's default VPC. Run via `terraform -chdir=e2e
# test`, which applies and destroys automatically. Requires real AWS
# credentials — see .github/workflows/e2e.yml.

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

module "addons" {
  source = "./.."

  name = var.name

  addons = {
    mysql     = { size = "mini" }
    redis     = { size = "mini" }
    memcached = { size = "mini" }
  }

  vpc_id              = data.aws_vpc.default.id
  subnet_ids          = data.aws_subnets.default.ids
  allowed_cidr_blocks = [data.aws_vpc.default.cidr_block]

  # Ephemeral lifecycle: no monitoring, no deletion protection, no final
  # snapshot — the whole point is destroying it right after.
  production_grade = false

  tags = {
    Component = "e2e"
  }
}
