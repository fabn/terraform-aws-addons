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
(`scaling` or `instance_class` for mysql/postgres, `node` for
redis/memcached) when the presets don't fit.

#### mysql / postgres — Aurora Serverless v2 (ACU ranges, 1 ACU = 2 GiB RAM)

Both SQL addons share the same presets, the same `scaling` / `instance_class`
escape hatches and the same contract — a stack picks either database
interchangeably (they both expose `DATABASE_URL`).

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
scales independently within it; readers double as failover targets. A reader
can depart from the cluster's class or failover priority through `instances`
(see mixed clusters below).

Slow queries are logged by default (`long_query_time = 2`s) and exported
to CloudWatch Logs; opt out with `slow_query_log = false`. mysql uses the
slow query log, postgres the equivalent `log_min_duration_statement`.
Automated backups are kept for 7 days (`backup_retention_period`).

##### Leaving Serverless v2 for a provisioned class

Serverless v2 is the default and stays the right one for most stacks: it
bills a floor continuously and pays off when load varies or disappears. A
database with a steady working set and no idle periods gets more memory per
euro from a fixed instance class, plus a buffer pool that does not resize
underneath the workload. That is a post-launch decision — a database starts
serverless, and the question arises once there is data to answer it.

```hcl
mysql = {
  size           = null            # the preset is an ACU range, so drop it
  instance_class = "db.r7g.large"  # ...and name the class instead
}
```

Three ways to size a SQL addon:

| | Sizing | Scales to zero |
|---|---|---|
| `size` | preset ACU range | mini/small only |
| `scaling` | custom ACU range | with `min_capacity = 0` |
| `instance_class` | fixed instance | no |

`size` is a preset ACU range and stands alone — setting it beside `scaling` or
`instance_class` fails at plan rather than silently ignoring it. The other two
do combine, and that combination is a mixed cluster (below).
`instance_class` rejects `db.serverless` itself: that is what `size` and
`scaling` already mean, and naming it there would build a serverless
cluster with no capacity range — accepted by Terraform, rejected by AWS.

**No provisioned presets**, deliberately. `instance_class` is the escape hatch
where the caller names the class, the way `scaling` already is for capacity.
The reason to leave Serverless v2 is a sizing review that concluded which class
wins; a `medium` that silently meant `db.r7g.large` would hide the decision
the caller came here to make.

##### Mixed clusters, and converting one to the other

Aurora runs Serverless v2 and provisioned instances side by side, and
prescribes exactly that shape for converting a running cluster from one to the
other: give a reader the target class, fail over onto it, then convert what
used to be the writer. Going through `instance_class` alone instead means
rebooting the writer.

`instances` names an instance and departs from the cluster default:

```hcl
mysql = {
  replicas  = 1
  instances = { "2" = { instance_class = "db.t4g.medium", promotion_tier = 0 } }
}
```

Keys are instance numbers, `"1"` through `1 + replicas`. They address
instances rather than roles — `"1"` is the writer *at creation*, and a failover
swaps that without anything in the configuration following it. They are also
the identifier suffixes AWS assigns (`<name>-<key>`), so lowering `replicas`
removes the highest-numbered instance whether or not a failover has made it
the writer.

Three things to know before reaching for this:

- **`promotion_tier` does more than order failover** on a Serverless v2
  instance. Tiers 0-1 hold a reader at no less than the writer's capacity so it
  can take over immediately, estimating an equivalent when the writer is
  provisioned; tiers 2-15 let it scale on its own workload. A serverless reader
  left in tier 0 beside a large provisioned writer bills for the writer's
  capacity.
- **A provisioned instance never auto-pauses**, and its presence keeps a
  Serverless v2 writer awake too. A cluster that scales to zero stops doing so
  the moment one is added.
- **The ACU range outlives the serverless instances.** AWS keeps a range it was
  once given, so a cluster converted to provisioned throughout goes on stating
  `scaling` beside `instance_class` — dropping it produces a diff that never
  applies.

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

#### Redis: slow log

The slow log is on by default: ElastiCache delivers it as JSON to a
CloudWatch log group named `/aws/elasticache/<name>`, which the addon
creates. On a single-threaded engine that log is worth having — it catches
the commands that block every other client, not merely slow ones.

```hcl
redis = {
  size     = "mini"
  slow_log = false # no delivery configuration, no log group
}
```

Turning it off is the way out when the caller's IAM is scoped to ElastiCache
alone: creating the log group needs CloudWatch Logs permissions, and without
them the apply fails on `AccessDenied`.

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

#### Redis: TLS and AUTH

By default the addon runs without either: traffic stays inside the VPC and the
security group is the whole access control. That is enough when the only
clients on that network are the ones meant to reach it, and it stops being
enough on a shared one — a security group admits a CIDR or a peer group, which
there means every workload on it. A token narrows access to the clients
actually given one.

```hcl
redis = {
  size                       = "small"
  transit_encryption_enabled = true
  auth_token_enabled         = true      # requires the line above
  transit_encryption_mode    = "required" # optional: preferred | required
}
```

AWS ties the two together — [`AuthToken` can be specified only on replication
groups where `TransitEncryptionEnabled` is
`true`](https://docs.aws.amazon.com/AmazonElastiCache/latest/APIReference/API_CreateReplicationGroup.html)
— so `auth_token_enabled` on its own is rejected at plan time, on the submodule
and on the addons map alike. The addon generates the token (`random_password`,
32 alphanumeric characters: comfortably above the 16-character floor AWS
imposes, and no percent-encoding needed in a URL) and moves the connection
string with it:

| | `env` | `sensitive_env` |
|---|---|---|
| default | `REDIS_URL` (`redis://host:6379`) | — |
| `transit_encryption_enabled` | `REDIS_URL` (`rediss://host:6379`) | — |
| `+ auth_token_enabled` | — | `REDIS_URL` (`rediss://:token@host:6379`), `REDIS_AUTH_TOKEN` |

`REDIS_URL` is published in one map or the other, never both: with a token it
is a credential, and a key appearing in both would reach the workload as a
ConfigMap and a Secret disagreeing about the same variable. Clients that read
`REDIS_URL` (redis-rb, Sidekiq, …) need no other change — the scheme is what
turns TLS on, and ElastiCache serves a certificate from a public CA, so there
is no trust store to configure. A caller that has to park the token somewhere
else instead (Secrets Manager, a Kubernetes Secret it builds itself) reads the
`auth_token` output.

`transit_encryption_mode` sets how strictly TLS is enforced while clients are
still being moved over:

| Mode | Accepts |
|---|---|
| `preferred` | encrypted **and** unencrypted connections |
| `required` | encrypted connections only |
| unset (default) | AWS chooses — `required` on a group created encrypted |

That is the migration path for a group that has none: `preferred` first, so
existing clients keep connecting while they are switched to `rediss://`, then
`required`. AWS documents the mode change as leaving the replication group in
place rather than replacing it. The token applies either way — `preferred`
relaxes the transport, not the credential.

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

#### When changes land

Addons apply their changes immediately: a modified configuration takes effect
on the next `terraform apply`, and the plan is the whole story. That is the
right default for an addon, and most modifications are non-disruptive anyway.

A few are not. Changing an instance class, a node type, an engine version, or
a static parameter needing a reboot costs a brief interruption — a failover on
the Aurora clusters, restarted (and cold) nodes on the ElastiCache ones. On a
production stack that interruption is better spent inside the maintenance
window than in the middle of a deploy:

```hcl
module "addons" {
  source = "fabn/addons/aws"
  # ...
  apply_immediately  = false                  # disruptive changes wait...
  maintenance_window = "sun:04:00-sun:05:00"  # ...for this window
}
```

`apply_immediately` (root, applied to **every** addon; also available on each
submodule) defaults to `true`. Two consequences of turning it off are worth
knowing before you do:

- **Deferred is not applied.** The change is accepted by AWS and stays pending
  until the window opens, so Terraform reports success and a later plan can
  look clean while the cluster is still running the old configuration.
- **It is only as predictable as the window.** With `maintenance_window = null`
  AWS picks a random window per addon, and a deferred change lands whenever
  that happens to be — which is why the two settings belong together.

Deploying often is itself an argument for leaving this `true`: waiting until
Monday night to see a change is usually worse than the interruption it avoids.

### Beyond an app-stack addon (mysql)

Three options the root wrapper does not expose, for callers using
`modules/mysql` directly as a database rather than as a stack addon.

**Extra engine parameters.** `cluster_parameters` is merged into the same
cluster parameter group the slow query log uses, and the group is created for
them even with `slow_query_log = false`. `apply_method` is yours to set: a
static parameter needs `"pending-reboot"` and a reboot before it takes effect,
and omitting it fails the apply rather than doing nothing quietly.

```hcl
cluster_parameters = [
  { name = "gtid_mode", value = "ON", apply_method = "pending-reboot" },
  { name = "enforce_gtid_consistency", value = "ON", apply_method = "pending-reboot" },
]
```

Two to know before reaching for them: `binlog_format` makes the cluster a
binary log source and the resulting activity stops a scale-to-zero cluster from
ever pausing; the two above are what a cluster needs to replicate from an
external MySQL server.

**An RDS-managed master password.** `manage_master_user_password = true` hands
the credential to RDS — minted, stored in Secrets Manager and rotatable — so
Terraform never learns it. `sensitive_env` is then empty, because there is no
password to compose a `DATABASE_URL` from, and `master_user_secret_arn` is
published instead. Right when the master user administers the database rather
than being the account the application connects as; wrong for an app stack,
which is why it is off by default.

**Monitoring, two flags.** `enhanced_monitoring` collects OS-level metrics
through an agent and creates an IAM role; `performance_insights` is enabled on
the instance and needs no role at all. Both default to `true`. Set only the
first to `false` when the Terraform principal is not allowed to create IAM
roles — a routine restriction for a role granted across accounts — and keep
query visibility that a single flag would have taken with it.

**Outbound access.** `egress_cidr_blocks` opens the security group for
connections the cluster *initiates*. Empty by default, which is right for a
database — but required when it replicates from a source outside the VPC, since
replication is outbound: the writer dials the source. With no egress rule the
connection never establishes, and `SHOW REPLICA STATUS` reports
`Can't connect to MySQL server` as though the source were down.

**The Data API.** `enable_http_endpoint = true` allows SQL over HTTPS with no
route into the VPC, and backs the console's query editor. Availability varies
by region and engine version, so an apply is the only reliable check.

### Cloning a SQL addon from an existing cluster (mysql / postgres)

Both SQL submodules can create the cluster as a copy of an existing one instead
of an empty database. An Aurora clone is copy-on-write against the source's
storage layer: the data is there in about two minutes largely regardless of
database size, and billed only for the pages it changes — which is what makes a
per-PR or per-environment database seeded from production-like data practical
at all.

The storage is the fast part; the compute is not. Measured end to end on a
throwaway clone: **cluster clone ~2 min, instance provisioning ~9.5 min,
destroy ~17 min.** So "ready in minutes regardless of size" is a statement
about the data, not about how soon the environment answers queries.

```hcl
module "review_app_db" {
  source  = "fabn/addons/aws//modules/postgres"

  name       = "myapp-pr-1234"
  clone_from = { source_cluster_identifier = "myapp-staging-postgres" }

  # The clone's own users and schemas came from the source, so name them.
  database               = "myapp_staging"
  username               = "app"
  source_master_password = var.staging_master_password

  vpc_id     = var.vpc_id
  subnet_ids = var.subnet_ids
}
```

`clone_from` defaults to a `copy-on-write` clone of the source's latest
restorable time — the two settings that make it a clone rather than a restore.
Pin `restore_to_time` for a fixed point instead, or `restore_type =
"full-copy"` for a real copy that costs full storage. Name the source with
either `source_cluster_identifier` or `source_cluster_resource_id`, not both.
`snapshot_identifier` is the sibling for restoring a snapshot; it is mutually
exclusive with `clone_from`.

**A clone inherits its credentials, and cannot be given different ones.** The
accounts live in the storage volume the clone shares with its source, and
`restore-db-cluster-to-point-in-time` exposes no `master-*` parameter at all —
there is no API surface through which credentials could be supplied at restore
time. Two consequences:

- The addon generates nothing, and `database` / `username` stop describing what
  it creates and start describing what it found. Pass the source's, or the
  connection vars will point at a database that isn't there.
- `source_master_password` **describes** that credential, it does not set it.
  Pass it and `sensitive_env` composes `DATABASE_URL` exactly as for an empty
  cluster; omit it and `sensitive_env` is empty, the same answer the addon gives
  when RDS owns the password. Pass it *wrong* and nothing fails at apply — the
  published URL simply will not authenticate.

`manage_master_user_password` is rejected in this mode. Not because handing the
inherited master to Secrets Manager is impossible, but because it cannot happen
*at creation*: the restore APIs take no such parameter, so the flag would be
silently dropped. `modify-db-cluster` does accept it, so rotating a clone's
master onto a managed secret is a later operation — one this addon does not
currently perform.

> **Every account on the source exists on the clone, with the source's
> passwords** — including whatever the application connects as. That is fine
> for a clone sharing its source's network and audience; it is worth thinking
> about for per-PR or per-developer databases, which usually have a *wider*
> audience than production. Rotating those accounts is an `ALTER USER` against
> the running clone: a job for whatever seeds the environment, not for
> Terraform.

**A clone is not a replica — unless its source was one.** Cloning does not
create inbound replication, so normally nothing keeps the writer busy and the
scale-to-zero sizes work exactly as on an empty cluster: `size = "mini"` (the
default) still auto-pauses, which is what makes idle review-app databases close
to free.

That holds only when the source was not itself an inbound binlog replica of an
external MySQL server. Replication *state* is not configuration and does not
live in the parameter group — it lives in InnoDB tables in the `mysql` schema,
on the very volume the clone shares. A clone of a replica therefore comes up at
first boot still pointing at its source's replication source, retrying
(`Replica_IO_Running: Connecting`) up to 86,400 times at 60-second intervals —
about sixty days — even when the security group gives it no egress and the
connection can never succeed.

**That alone prevents auto-pause**, verified by controlled test: with the
inherited channel the cluster pinned at its ceiling and never paused; after
resetting it, the same cluster scaled to zero. For a per-PR clone this inverts
the cost argument — a cluster doing nothing sits at maximum capacity. Clear it
on the clone with:

```sql
CALL mysql.rds_stop_replication();
CALL mysql.rds_reset_external_source();
```

No downtime, but note the ordering below: those calls need the Data API, which
on a restored cluster needs a second apply.

**The Data API cannot be enabled while restoring.** `enable_http_endpoint =
true` is passed through correctly, and AWS discards it: neither
`restore-db-cluster-to-point-in-time` nor `restore-db-cluster-from-snapshot`
has that parameter, though `create-db-cluster` and `modify-db-cluster` both do.
The apply succeeds, AWS reports `HttpEndpointEnabled: False`, and Terraform
records `false` — so there is no drift to notice, just a second plan proposing
`false -> true` that takes about 1m45s to apply.

The consequence is an ordering one: **anything a caller wants to do over the
Data API immediately after creating a clone is gated behind a second apply** —
including creating the application accounts, which is the first thing a cloned
environment needs.

**A clone gets the addon's parameter group, not the source's.** Parameters are
configuration rather than data, so nothing carries them across a clone on its
own — and adopting them would be the wrong default anyway. A clone of a cluster
carrying `binlog_format` or `gtid_mode` would come up configured as a
replication source it is not, and that binlog activity alone would stop a
scale-to-zero clone from ever pausing, which is most of the reason a per-PR
clone is cheap. A caller who wants the source's engine settings restates them
in `cluster_parameters` (mysql).

Two limits worth knowing before cloning in a loop:

- AWS allows **fifteen copy-on-write clones per source cluster**. The sixteenth
  does not fail — it silently becomes a full copy, same API call, entirely
  different time and bill. Nothing here can detect that at plan time, so a
  caller creating clones in a loop should cap them itself.
- A cluster's lineage is fixed at creation. Pointing `clone_from` at a
  different source later **replaces** the cluster rather than re-cloning it.

`restored_from` reports the resolved mode and source (`null` for an empty
cluster), since the restore arguments themselves cannot be read back.

### Addons

| Addon | Backed by | env | sensitive_env |
|-----------|-----------|-----|---------------|
| mysql | Aurora MySQL Serverless v2 ([terraform-aws-modules/rds-aurora](https://github.com/terraform-aws-modules/terraform-aws-rds-aurora)) | `MYSQL_HOST`, `MYSQL_PORT`, `MYSQL_USER`, `MYSQL_DATABASE` | `DATABASE_URL` (mysql2 scheme), `MYSQL_PASSWORD` |
| postgres | Aurora PostgreSQL Serverless v2 ([terraform-aws-modules/rds-aurora](https://github.com/terraform-aws-modules/terraform-aws-rds-aurora)) | `PGHOST`, `PGPORT`, `PGUSER`, `PGDATABASE` | `DATABASE_URL` (postgresql scheme), `PGPASSWORD` |
| redis | ElastiCache Redis / Valkey ([terraform-aws-modules/elasticache](https://github.com/terraform-aws-modules/terraform-aws-elasticache)) | `REDIS_URL` | — (with `auth_token_enabled`: `REDIS_URL` moves here, alongside `REDIS_AUTH_TOKEN`) |
| memcached | ElastiCache Memcached ([terraform-aws-modules/elasticache](https://github.com/terraform-aws-modules/terraform-aws-elasticache)) | `MEMCACHED_SERVERS` (comma-separated `host:port` list) | — |

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
