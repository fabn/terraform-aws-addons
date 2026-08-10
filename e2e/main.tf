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

  # `small` on the Aurora addon, not `mini`, and it is a monitoring fix rather
  # than a capacity one. ACUUtilization is capacity ÷ max_capacity, so on
  # `mini` (max = 1 ACU) a cluster that is merely awake reads 50–100% — the
  # floor is 0.5 ACU and a freshly created one sits at 1. That tripped the
  # "Aurora out of capacity headroom" monitor (>85% for 30m) on a cluster with
  # **zero connections**, which lives about fifteen minutes. `small` doubles the
  # ceiling to 2 ACU, so the same idle cluster reads 25–50% and the alert means
  # what it says.
  #
  # It costs nothing: max_capacity is a ceiling, not a reservation — Aurora
  # bills the ACU-hours actually consumed, and this cluster consumes the same
  # ones either way.
  #
  # ⚠️ `mini` is still the module default (main.tf), so anything that takes it
  # without saying so inherits the same blind spot. Fixing it there means either
  # excluding ephemeral clusters from the monitor by tag or making the alert
  # capacity-aware; this only fixes the harness that kept firing it.
  addons = {
    mysql     = { size = "small" }
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
