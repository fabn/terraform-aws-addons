# Terraform AWS Addons Module

AWS-based backing services (addons) for application stacks deployed with
[fabn/formation/kubernetes](https://registry.terraform.io/modules/fabn/formation/kubernetes):
this repository is its companion for addons backed by AWS managed services
instead of in-cluster workloads.

Published on the Terraform Registry as
[`fabn/addons/aws`](https://registry.terraform.io/modules/fabn/addons/aws).

## Design

Addons follow the same uniform contract as the in-cluster addons of the
formation module — each addon is an independent submodule under `modules/`
that outputs:

- `env` — plaintext configuration (hosts, ports, URLs)
- `sensitive_env` — credentials

The caller merges both into the stack (`env` / `secret_env` of the formation
module), Heroku-addon style. New backing services are new addon modules,
never new toggles in an existing one.

## Usage

### Root wrapper (formation-style)

The root module wraps the submodules behind a single Heroku-like `addons`
map — one entry per backing service, sized with a preset plan:

```hcl
module "addons" {
  source  = "fabn/addons/aws"
  version = "~> 0.1"

  name = "myapp-staging"

  addons = {
    mysql     = { size = "medium" }
    redis     = { size = "mini" }
    memcached = { size = "mini" }
  }

  vpc_id                     = var.vpc_id
  subnet_ids                 = var.private_subnet_ids
  allowed_security_group_ids = [var.eks_node_security_group_id]
}

module "app" {
  source  = "fabn/formation/kubernetes"
  version = "~> 0.7"

  # ...
  env        = merge(module.addons.env, { RAILS_ENV = "production" })
  secret_env = module.addons.sensitive_env
}
```

### Individual submodules

Every addon stays usable on its own (and exposes more knobs than the
wrapper):

```hcl
module "mysql" {
  source  = "fabn/addons/aws//modules/mysql"
  version = "~> 0.1"

  name       = "myapp-staging-mysql"
  size       = "small"
  vpc_id     = var.vpc_id
  subnet_ids = var.private_subnet_ids
}
```

### Sizes

Each addon accepts a Heroku-style `size` preset. The variable is nullable:
set `size = null` and pass the addon-specific resources variable instead
(`scaling` for mysql/postgres, `node` for redis/memcached) when the presets
don't fit.

#### mysql / postgres — Aurora Serverless v2 (ACU ranges, 1 ACU = 2 GiB RAM)

Both SQL addons share the same presets, the same `scaling` escape hatch and
the same contract — a stack picks either database interchangeably (they both
expose `DATABASE_URL`).

| Size | Min ACU | Max ACU | Scales to zero |
|--------|---------|---------|------------------|
| mini | 0 | 1 | after 5 min idle |
| small | 0 | 2 | after 5 min idle |
| medium | 0.5 | 4 | no (warm floor) |
| large | 1 | 8 | no (warm floor) |

Custom capacity: `size = null` +
`scaling = { min_capacity = 0, max_capacity = 16, seconds_until_auto_pause = 600 }`
(scale-to-zero requires `min_capacity = 0` and Aurora MySQL >= 3.08 /
Aurora PostgreSQL >= 15.4).

Readers: `replicas = n` adds reader instances (default 0, writer only).
Serverless v2 readers share the cluster's ACU range but each instance
scales independently within it; readers double as failover targets.

Slow queries are logged by default (`long_query_time = 2`s) and exported
to CloudWatch Logs; opt out with `slow_query_log = false`. mysql uses the
slow query log, postgres the equivalent `log_min_duration_statement`.
Automated backups are kept for 7 days (`backup_retention_period`).

#### redis / memcached — ElastiCache node types

| Size | Node type | Memory |
|--------|------------------|----------|
| mini | cache.t4g.micro | ~0.5 GiB |
| small | cache.t4g.small | ~1.4 GiB |
| medium | cache.t4g.medium | ~3.1 GiB |
| large | cache.m7g.large | ~6.4 GiB |

Custom nodes: `size = null` + `node = { node_type = "cache.r7g.xlarge" }`
(redis; add `num_nodes` for multi-node memcached).

#### Redis: queue vs cache posture

The redis defaults suit a queue backend (Sidekiq): `maxmemory_policy =
"noeviction"` and one day of RDB snapshots. When Redis is a cache, flip
both:

```hcl
redis = {
  size                     = "small"
  maxmemory_policy         = "allkeys-lru"
  snapshot_retention_limit = 0 # opt out of persistence
  replicas                 = 1 # optional HA
}
```

There is no Redis Sentinel on ElastiCache: with `replicas > 0` the addon
enables automatic failover — a replica is promoted and the primary endpoint
DNS follows, no sentinel-aware client needed. Add `multi_az_enabled = true`
(submodule) for AZ-spread placement.

#### Redis: engine (redis vs valkey)

ElastiCache offers [Valkey](https://valkey.io) — the Redis-compatible fork —
at a lower price than Redis OSS for the same node types. It speaks the same
protocol, so the addon contract does not change: `REDIS_URL` and existing
clients (redis-rb, Sidekiq, …) keep working unchanged. Redis OSS stays the
default; opt into Valkey per addon:

```hcl
redis = {
  size   = "small"
  engine = "valkey" # redis (default) | valkey
}
```

Switching the engine also switches the parameter group family default
(`redis7` → `valkey8`); `engine_version` and `parameter_group_family` are
still overridable on the submodule (e.g. `engine = "valkey"` with
`parameter_group_family = "valkey7"`).

#### Maintenance & backup windows

By default AWS scatters each addon's maintenance across a random window. The
wrapper instead pins them to an off-peak nighttime slot (UTC) so patches and
engine upgrades land predictably:

- `maintenance_window` (root, applied to **every** addon) — a weekly UTC
  window, `ddd:hh24:mi-ddd:hh24:mi`; defaults to `mon:03:00-mon:04:00`
  (Monday night). Forwarded to the Aurora clusters
  (`preferred_maintenance_window`) and the ElastiCache addons
  (`maintenance_window`).
- `backup_window` (root, applied to every addon that persists data) — a
  daily UTC window, `hh24:mi-hh24:mi`; defaults to `01:00-02:00`, just before
  the maintenance window (the two must not overlap). Forwarded to the Aurora
  clusters (`preferred_backup_window`) and to the redis RDB snapshot
  (`snapshot_window`, ignored when `snapshot_retention_limit = 0`).

```hcl
module "addons" {
  source = "fabn/addons/aws"
  # ...
  maintenance_window = "sun:04:00-sun:05:00" # move the shared window
  backup_window      = null                  # or let AWS randomize this one
}
```

Set either to `null` to hand the choice back to AWS. For per-addon windows,
use the submodules directly — mysql/postgres take
`preferred_maintenance_window` + `preferred_backup_window`, redis takes
`maintenance_window` + `snapshot_window`, memcached takes
`maintenance_window`.

### Addons

| Addon | Backed by | env | sensitive_env |
|-----------|-----------|-----|---------------|
| mysql | Aurora MySQL Serverless v2 ([terraform-aws-modules/rds-aurora](https://github.com/terraform-aws-modules/terraform-aws-rds-aurora)) | `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_DATABASE` | `DATABASE_URL` (mysql2 scheme), `MYSQL_PASSWORD` |
| postgres | Aurora PostgreSQL Serverless v2 ([terraform-aws-modules/rds-aurora](https://github.com/terraform-aws-modules/terraform-aws-rds-aurora)) | `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` | `DATABASE_URL` (postgresql scheme), `PGPASSWORD` |
| redis | ElastiCache Redis / Valkey ([terraform-aws-modules/elasticache](https://github.com/terraform-aws-modules/terraform-aws-elasticache)) | `REDIS_URL` | — |
| memcached | ElastiCache Memcached ([terraform-aws-modules/elasticache](https://github.com/terraform-aws-modules/terraform-aws-elasticache)) | `MEMCACHED_SERVER_URL` | — |

## Examples

- [examples/stack](examples/stack) — root wrapper with the formation-style
  addons map
- [examples/mysql](examples/mysql) — standalone submodule with custom
  Serverless v2 capacity
- [examples/postgres](examples/postgres) — standalone postgres submodule
  with custom Serverless v2 capacity

## Requirements

| Name | Version |
|------|---------|
| terraform | >= 1.11.1 |
| aws | >= 6.54, < 7.0 |
| random | ~> 3.6 |

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

### E2E

The e2e suite provisions the full stack (mini sizes) on a real AWS account
and destroys it afterwards (~25 minutes, Aurora dominates — a few cents per
run). It is not part of the PR feedback loop: it runs on pushes to `main`
and on demand (`workflow_dispatch`) before cutting a release, and stays
skipped until the `AWS_E2E_ROLE_ARN` / `AWS_E2E_REGION` repository
variables (GitHub OIDC) are configured.

```bash
terraform -chdir=e2e init
terraform -chdir=e2e test
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
