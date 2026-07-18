# Standalone MySQL addon with custom Serverless v2 capacity: the preset
# sizes are opted out (size = null) in favour of an explicit ACU range that
# still scales to zero.

module "mysql" {
  source = "../../modules/mysql"

  name = "myapp-staging-mysql"

  size = null
  scaling = {
    min_capacity             = 0
    max_capacity             = 16
    seconds_until_auto_pause = 600
  }

  database = "myapp"

  vpc_id              = var.vpc_id
  subnet_ids          = var.subnet_ids
  allowed_cidr_blocks = var.allowed_cidr_blocks

  tags = {
    env = "staging"
  }
}
