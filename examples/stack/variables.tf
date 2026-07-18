variable "vpc_id" {
  description = "VPC where the addons are created."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnets for the addon subnet groups."
  type        = list(string)
}

variable "allowed_security_group_ids" {
  description = "Security groups allowed to reach the addons (e.g. the EKS node security group)."
  type        = list(string)
  default     = []
}
