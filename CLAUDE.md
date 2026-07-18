# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

Terraform module hosting AWS-based addons (backing services) for application
stacks deployed with
[fabn/formation/kubernetes](https://github.com/fabn/terraform-kubernetes-formation),
its companion repository. Published on the Terraform Registry as
`fabn/addons/aws`.

Addons follow the same uniform contract as the formation's in-cluster addons:
each addon is an independent submodule under `modules/` that outputs `env`
(plaintext config) and `sensitive_env` (credentials), merged into the stack by
the caller, Heroku-addon style. New backing services are new addon modules,
never new toggles in an existing one.

The root module is a formation-style wrapper: a single `addons` map (one
entry per backing service, Heroku-like `size` presets) that deploys the
matching submodules and merges their env outputs.

## Contribution Conventions

- **English everywhere** — code, comments, commit messages, issues, PRs.
- **PRs**: use `Closes #<n>` when the PR addresses a tracked issue; keep the
  description coherent with what is actually implemented — if the diff
  changes during review, update the description before merging.

## Commands

### Toolchain

Tools (terraform, lefthook, actionlint) are pinned in `mise.toml`:

```bash
mise install
```

### Terraform Operations

```bash
# Format check (recursive)
terraform fmt -check -recursive

# Format files
terraform fmt -recursive

# Initialize module
terraform init

# Validate terraform
terraform validate

# Run unit tests (mocked providers, no AWS account needed)
terraform test

# Run specific test
terraform test -filter=tests/mysql.tftest.hcl

# Run E2E tests (real AWS account, applies and destroys, ~25 minutes)
terraform -chdir=e2e init
terraform -chdir=e2e test
```

### Git Hooks (Lefthook)

```bash
# Install hooks
lefthook install

# Run all validations manually
lefthook run validate-all

# Pre-commit runs: actionlint, terraform fmt (with auto-fix)
# Pre-push runs: actionlint, terraform fmt -check, terraform validate
```

## Architecture

### Module Structure

```
.
├── main.tf              # Root wrapper: addons map => submodule instances
├── variables.tf         # Input variables (addons map + shared network/lifecycle)
├── outputs.tf           # Merged env/sensitive_env + per-addon details
├── versions.tf          # Provider requirements (aws >= 6.54, random ~> 3.6)
│
├── modules/             # Addon submodules
│   ├── mysql/           # Aurora MySQL Serverless v2 (terraform-aws-modules/rds-aurora)
│   ├── postgres/        # Aurora PostgreSQL Serverless v2 (terraform-aws-modules/rds-aurora)
│   ├── redis/           # ElastiCache Redis (terraform-aws-modules/elasticache)
│   └── memcached/       # ElastiCache Memcached (terraform-aws-modules/elasticache)
│
├── examples/            # Usage examples
│   ├── stack/           # Root wrapper, formation-style addons map
│   ├── mysql/           # Standalone submodule with custom scaling
│   └── postgres/        # Standalone postgres submodule with custom scaling
│
├── tests/               # Unit tests (mocked providers)
└── e2e/                 # E2E harness + tests (real AWS account)
```

### Key Design Decisions

- **Same addon contract as the formation module**: submodules output `env` +
  `sensitive_env`; the caller merges them into the stack. Keeps AWS-backed
  and in-cluster addons interchangeable from the stack's point of view.
- **Addons are separate modules, not core toggles**: addons have different
  lifecycles; per-environment addon swaps stay invisible to the rest of the
  stack.
- **Built on the official terraform-aws-modules**: `rds-aurora` and
  `elasticache`, for a uniform syntax across addons — this repo only adds
  the addon contract, the sizes and opinionated defaults on top.
- **Heroku-style sizes**: every addon takes a nullable `size` preset
  (mini/small/medium/large); `size = null` + the addon-specific variable
  (`scaling` for mysql/postgres ACU ranges, `node` for cache node type/count)
  is the escape hatch for custom capacity. Exactly one of the two must be set
  (enforced by cross-variable validation).
- **mysql/postgres are interchangeable siblings**: same rds-aurora base,
  same sizes/scaling, both export `DATABASE_URL` — a stack picks one SQL
  database. Aligned with the formation module's in-cluster addons.
- **SQL scales to zero**: Serverless v2 with `min_capacity = 0` +
  auto-pause on the mini/small sizes; slow query logging goes through a
  dedicated cluster parameter group (dynamic parameters only — nothing like
  mysql's binlog_format that would keep the cluster from pausing).
- **Unit tests use `mock_provider`**: no AWS account or credentials needed
  in CI; endpoints are mock values so assertions target contract shape and
  size resolution, not concrete hostnames.

## Testing

- `tests/` — unit tests with `mock_provider`, no AWS account needed.
  Assertions on planned values (naming, validation rules, addon env
  contracts, size resolution).
- `e2e/` — a root module provisioning the full stack (mini sizes, ephemeral
  lifecycle) in the default VPC of a real AWS account; `terraform test`
  applies, asserts real endpoints and destroys. Runs from
  `.github/workflows/e2e.yml` on pushes to main / manual dispatch, skipped
  until the `AWS_E2E_ROLE_ARN` repository variable (GitHub OIDC) is set.

## CI/CD

- **GitHub Actions** — fmt/validate + unit tests (`test.yml`,
  `terraform-check.yml`), actionlint (`actionlint.yml`), e2e on main/dispatch
  (`e2e.yml`)
- **Release Drafter** (v7) — automatic release notes generation; registry
  releases are git tags (`v*`)
- **Dependabot** — dependency updates (github-actions + terraform)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and add tests
4. Run `lefthook run validate-all`
5. Submit a pull request
