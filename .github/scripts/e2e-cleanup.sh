#!/usr/bin/env bash
# Deletes what an e2e run left behind. `terraform test` destroys everything it
# creates, failed assertions included, so this is for the runs that never reach
# that point: the job timeout, a cancellation, a runner that dies. Their state
# lives on the runner and dies with it, leaving nothing to plan a destroy from.
#
# By name, not by tag: every resource that matters carries a fixed name derived
# from TF_VAR_name, and the OIDC role is scoped to rds and elasticache with no
# tagging-API read.
#
# WAIT=1 runs before the suite and blocks until AWS reports everything gone, so
# the apply cannot collide with a carcass. WAIT=0 runs after it, inside the few
# minutes GitHub allows a cancelled job: it fires the deletes and returns, which
# is what stops the bill — Aurora charges for the instance, not for the empty
# cluster the next pre-run sweep collects.

set -euo pipefail

name="${TF_VAR_name:?TF_VAR_name must be set}"
blocking="${WAIT:-0}"

cluster="${name}-mysql"
redis="${name}-redis"
memcached="${name}-memcached"

leftover() {
  echo "::warning title=e2e leftover::${1} outlived its run, deleting it"
}

if aws rds describe-db-clusters --db-cluster-identifier "$cluster" >/dev/null 2>&1; then
  leftover "Aurora cluster $cluster"
  members=$(aws rds describe-db-clusters --db-cluster-identifier "$cluster" \
    --query 'DBClusters[0].DBClusterMembers[].DBInstanceIdentifier' \
    --output text 2>/dev/null || true)
  if [ "$members" = "None" ]; then
    members=""
  fi
  for member in $members; do
    aws rds delete-db-instance --db-instance-identifier "$member" \
      --skip-final-snapshot --delete-automated-backups >/dev/null 2>&1 || true
  done
  if [ "$blocking" = 1 ]; then
    for member in $members; do
      aws rds wait db-instance-deleted --db-instance-identifier "$member"
    done
    aws rds delete-db-cluster --db-cluster-identifier "$cluster" \
      --skip-final-snapshot >/dev/null 2>&1 || true
    aws rds wait db-cluster-deleted --db-cluster-identifier "$cluster"
    aws rds delete-db-subnet-group --db-subnet-group-name "$cluster" >/dev/null 2>&1 || true
  else
    # Fired anyway: it fails while the instances are still deleting, and
    # succeeds when the run leaked a cluster that never got one.
    aws rds delete-db-cluster --db-cluster-identifier "$cluster" \
      --skip-final-snapshot >/dev/null 2>&1 || true
  fi
fi

if aws elasticache describe-replication-groups --replication-group-id "$redis" >/dev/null 2>&1; then
  leftover "Redis replication group $redis"
  aws elasticache delete-replication-group --replication-group-id "$redis" \
    --no-retain-primary-cluster >/dev/null 2>&1 || true
  if [ "$blocking" = 1 ]; then
    aws elasticache wait replication-group-deleted --replication-group-id "$redis"
    aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$redis" >/dev/null 2>&1 || true
  fi
fi

if aws elasticache describe-cache-clusters --cache-cluster-id "$memcached" >/dev/null 2>&1; then
  leftover "Memcached cluster $memcached"
  aws elasticache delete-cache-cluster --cache-cluster-id "$memcached" >/dev/null 2>&1 || true
  if [ "$blocking" = 1 ]; then
    aws elasticache wait cache-cluster-deleted --cache-cluster-id "$memcached"
    aws elasticache delete-cache-subnet-group --cache-subnet-group-name "$memcached" >/dev/null 2>&1 || true
  fi
fi

# Parameter groups and security groups are left to the next apply: the modules
# name them with a random suffix, so a stale one is inert rather than a
# collision, and deleting them needs the clusters to be fully gone first.
