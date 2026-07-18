terraform {
  # 1.11 for the write-only master password argument (rds-aurora ~> 10.0).
  required_version = ">= 1.11.1"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.54, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}
