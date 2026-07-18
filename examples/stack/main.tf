# Formation-style stack: one addons map, Heroku-like sizes, merged env
# outputs ready to feed the fabn/formation/kubernetes module.

module "addons" {
  source = "../.."

  name = "myapp-staging"

  addons = {
    mysql     = { size = "medium" }
    redis     = { size = "mini" }
    memcached = { size = "mini" }
  }

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
  # Let the EKS nodes reach the addons.
  allowed_security_group_ids = var.allowed_security_group_ids

  tags = {
    env = "staging"
  }
}

# The addons plug into the formation module Heroku-style — the stack only
# sees env vars:
#
#   module "app" {
#     source  = "fabn/formation/kubernetes"
#     version = "~> 0.7"
#
#     # ...
#     env        = merge(module.addons.env, { RAILS_ENV = "production" })
#     secret_env = module.addons.sensitive_env
#   }
