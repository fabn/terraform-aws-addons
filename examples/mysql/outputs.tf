output "env" {
  description = "Plaintext connection vars."
  value       = module.mysql.env
}

output "sensitive_env" {
  description = "Credential vars."
  sensitive   = true
  value       = module.mysql.sensitive_env
}

output "host" {
  description = "Writer endpoint."
  value       = module.mysql.host
}
