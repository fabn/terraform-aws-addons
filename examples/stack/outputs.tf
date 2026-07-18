output "env" {
  description = "Merged plaintext config vars for the stack."
  value       = module.addons.env
}

output "sensitive_env" {
  description = "Merged credential vars for the stack."
  sensitive   = true
  value       = module.addons.sensitive_env
}
