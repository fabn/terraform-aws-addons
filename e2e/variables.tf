variable "name" {
  description = "Stack name for the e2e run. Override to avoid collisions between concurrent runs."
  type        = string
  default     = "aws-addons-e2e"
}
