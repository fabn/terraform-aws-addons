# Terraform AWS Addons Module

AWS-based backing services (addons) for application stacks deployed with
[fabn/formation/kubernetes](https://registry.terraform.io/modules/fabn/formation/kubernetes):
this repository is its companion for addons backed by AWS managed services
instead of in-cluster workloads.

Published on the Terraform Registry as
[`fabn/addons/aws`](https://registry.terraform.io/modules/fabn/addons/aws).

## Status

**Scaffolding.** The root module is a no-op placeholder used to validate the
repository structure, the CI pipeline and registry publishing. The first
addon modules will land under `modules/` next.

## Design

Addons follow the same uniform contract as the in-cluster addons of the
formation module — each addon is an independent submodule under `modules/`
that outputs:

- `env` — plaintext configuration (hosts, ports, URLs)
- `sensitive_env` — credentials

The caller merges both into the stack (`env` / `secret_env` of the formation
module), Heroku-addon style. New backing services are new addon modules,
never new toggles in an existing one.

```hcl
module "app" {
  source  = "fabn/formation/kubernetes"
  version = "~> 0.1"

  # ...
  env        = merge(module.some_aws_addon.env, { RAILS_ENV = "production" })
  secret_env = module.some_aws_addon.sensitive_env
}
```

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.9 |
| aws | ~> 6.0 |

## Development

Toolchain is managed with [mise](https://mise.jdx.dev) — run `mise install`
once after cloning, then install the git hooks:

```bash
mise install
lefthook install
```

### Testing

Unit tests run against mocked providers, no AWS account needed:

```bash
terraform init && terraform test
```

### Validation

```bash
# All validations (actionlint, terraform fmt -check, terraform validate)
lefthook run validate-all
```

## Releasing

Release notes are drafted automatically by
[Release Drafter](https://github.com/release-drafter/release-drafter);
registry releases are git tags (`v*`) published from the drafted release.

## License

Apache 2.0 — see [LICENSE](LICENSE).
