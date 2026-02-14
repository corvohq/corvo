# Corvo Helm Chart

## Install

```bash
helm install corvo ./deploy/helm/corvo
```

## Cluster mode

```bash
helm install corvo ./deploy/helm/corvo \
  --set single.enabled=false \
  --set cluster.enabled=true \
  --set cluster.replicas=3
```

This chart supports:
- Single-node Deployment (`single.enabled=true`, default)
- Clustered StatefulSet with DNS discovery (`cluster.enabled=true`)
