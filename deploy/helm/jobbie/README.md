# Jobbie Helm Chart

## Install

```bash
helm install jobbie ./deploy/helm/jobbie
```

## Cluster mode

```bash
helm install jobbie ./deploy/helm/jobbie \
  --set single.enabled=false \
  --set cluster.enabled=true \
  --set cluster.replicas=3
```

This chart supports:
- Single-node Deployment (`single.enabled=true`, default)
- Clustered StatefulSet with DNS discovery (`cluster.enabled=true`)
