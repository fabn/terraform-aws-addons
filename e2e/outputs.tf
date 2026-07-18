output "env" {
  description = "Merged plaintext config vars of the provisioned addons."
  value       = module.addons.env
}

output "sensitive_env" {
  description = "Merged credential vars of the provisioned addons."
  sensitive   = true
  value       = module.addons.sensitive_env
}
