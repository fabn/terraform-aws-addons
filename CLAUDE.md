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

The root module is currently a no-op placeholder that validates the
repository structure, CI and registry publishing; the first addons will land
under `modules/`.

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
terraform test -filter=tests/placeholder.tftest.hcl
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
├── main.tf              # Placeholder root module (no-op scaffold)
├── variables.tf         # Input variables
├── outputs.tf           # Output values
├── versions.tf          # Provider requirements (aws ~> 6.0)
│
├── modules/             # Addon submodules (to come)
│
└── tests/               # Unit tests (mocked providers)
```

### Key Design Decisions

- **Same addon contract as the formation module**: submodules output `env` +
  `sensitive_env`; the caller merges them into the stack. Keeps AWS-backed
  and in-cluster addons interchangeable from the stack's point of view.
- **Addons are separate modules, not core toggles**: addons have different
  lifecycles; per-environment addon swaps stay invisible to the rest of the
  stack.
- **Unit tests use `mock_provider`**: no AWS account or credentials needed in
  CI.

## Testing

- `tests/` — unit tests with `mock_provider`, no AWS account needed.
  Assertions on planned values (naming, validation rules, addon env
  contracts).

## CI/CD

- **GitHub Actions** — fmt/validate + unit tests (`test.yml`,
  `terraform-check.yml`), actionlint (`actionlint.yml`)
- **Release Drafter** (v7) — automatic release notes generation; registry
  releases are git tags (`v*`)
- **Dependabot** — dependency updates (github-actions + terraform)

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make changes and add tests
4. Run `lefthook run validate-all`
5. Submit a pull request
