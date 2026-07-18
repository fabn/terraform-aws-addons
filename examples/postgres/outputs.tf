output "env" {
  description = "Plaintext connection vars."
  value       = module.postgres.env
}

output "sensitive_env" {
  description = "Credential vars."
  sensitive   = true
  value       = module.postgres.sensitive_env
}

output "host" {
  description = "Writer endpoint."
  value       = module.postgres.host
}
