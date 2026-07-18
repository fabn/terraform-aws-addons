variable "name" {
  description = "Placeholder input, echoed back by the placeholder output. Will be replaced when the first addon lands."
  type        = string
  default     = "aws-addons"

  validation {
    condition     = length(var.name) > 0
    error_message = "name must not be empty."
  }
}
