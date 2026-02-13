# Jobbie Managed Infrastructure Slice

This repository includes a reference managed-infrastructure slice for clustered Jobbie deployment.

## Included

- 3-node Jobbie cluster (`deploy/cloud/docker-compose.yml`)
- ingress/load-balancer tier (`nginx`)
- persistent node-local volumes
- leader failover via built-in Raft

## Operations model

- External clients use ingress endpoint (`:18080`)
- Any node can receive requests; follower writes proxy to leader
- API-key auth + namespace + RBAC is enabled by server middleware
- Audit logs and billing summaries are exposed via API

## Next hardening steps

- Move from compose to Kubernetes + managed LB
- Add TLS termination and cert rotation
- Centralized metrics/traces/log collection (Prometheus + OTEL collector)
- Managed backups via scheduled `/api/v1/admin/backup` export and restore workflows
