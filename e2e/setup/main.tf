# Network the probes attach to: the account's default VPC, same as the harness
# root. A setup module rather than data sources in the test file, because a run
# block that overrides `module` no longer sees the harness root.

terraform {
  required_version = ">= 1.11.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.54, < 7.0"
    }
  }
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

output "vpc_id" {
  description = "Default VPC of the e2e account."
  value       = data.aws_vpc.default.id
}

output "subnet_ids" {
  description = "Subnets of the default VPC."
  value       = data.aws_subnets.default.ids
}

output "cidr_block" {
  description = "CIDR of the default VPC, for the addon's ingress rule."
  value       = data.aws_vpc.default.cidr_block
}
