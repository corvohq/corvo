# Authentication & Authorization

Corvo supports API-key auth in OSS and optional enterprise SSO + custom RBAC under license.

Auth behavior today:

- If there are zero enabled API keys, requests run as admin (development bootstrap mode).
- Once at least one API key exists, all `/api/v1` requests require auth.
- API key auth accepts either `X-API-Key` or `Authorization: Bearer <api-key>`.
- API keys are stored hashed (SHA-256) in SQLite and managed via API endpoints.

---

## Quick start

Create your first admin key:

```bash
curl -s -X POST http://localhost:8080/api/v1/auth/keys \
  -H 'Content-Type: application/json' \
  -d '{"name":"admin","key":"jb_dev_admin_123","role":"admin","namespace":"default"}'
```

Use the key:

```bash
curl -s http://localhost:8080/api/v1/queues -H 'X-API-Key: jb_dev_admin_123'
```

Or with Bearer:

```bash
curl -s http://localhost:8080/api/v1/queues -H 'Authorization: Bearer jb_dev_admin_123'
```

---

## OSS: API key auth

### Key format

Keys should be generated with sufficient entropy (32+ bytes, base62 encoded). Convention: prefix with `jb_` and an environment hint for easy identification.

```
jb_prod_a1b2c3d4e5f6...    # production
jb_dev_x9y8z7w6v5u4...     # development
jb_test_m3n4o5p6q7r8...    # testing
```

Corvo can auto-generate keys if `key` is omitted in create requests, but supplying your own is recommended. Example:

```bash
openssl rand -base64 32 | tr -d '=/+' | sed 's/^/jb_prod_/'
```

### Key management API

```text
POST   /api/v1/auth/keys
GET    /api/v1/auth/keys
DELETE /api/v1/auth/keys
```

Create/update body:

```json
{
  "name": "email-workers",
  "key": "jb_prod_abc123...",
  "namespace": "default",
  "role": "worker",
  "queue_scope": "emails.*",
  "enabled": true
}
```

### Roles

Four built-in roles.

| Role | Permissions |
|---|---|
| `worker` | enqueue, fetch, ack, fail, heartbeat, progress, batch enqueue, batch ack |
| `readonly` | search, get job, list queues, list workers, list budgets, usage summary, SSE events, UI read access |
| `operator` | operational endpoints except key mutation (can list keys, but not create/delete) |
| `admin` | everything: all worker permissions, all read permissions, plus queue management (pause, resume, drain, clear, delete, concurrency, throttle), job management (retry, cancel, hold, approve, reject, delete, move, replay), bulk operations, budget management, cluster admin |

The `worker` role is intentionally limited. Workers can enqueue and process jobs but cannot pause queues, retry dead jobs, or approve held jobs. This follows the principle of least privilege — a compromised worker token cannot disrupt queue operations.

### Queue scoping

The `queue_scope` field accepts glob patterns:

```yaml
queue_scope: "*"           # all queues
queue_scope: "emails.*"    # emails.send, emails.bulk, etc.
queue_scope: "emails.send" # only emails.send
```

Queue scoping is enforced on all operations:

- **fetch** — can only fetch from matching queues
- **enqueue** — can only enqueue to matching queues
- **search** — results filtered to matching queues
- **queue management** — can only pause/resume/etc. matching queues
- **job operations** — can only retry/cancel/approve jobs in matching queues

A `readonly` key with `queue_scope: "emails.*"` can only see email jobs in search results and the UI.

### Auth disabled (development mode)

When no enabled API keys exist, all requests are treated as admin. As soon as a key is created/enabled, auth is enforced.

### Auth on the UI

When auth is enabled, the UI requires a token. Options:

1. **Login page** — enter an API key, stored in localStorage. Simple, works for small teams.
2. **Proxy auth** — put Corvo behind an authenticating reverse proxy (nginx, Cloudflare Access, etc.) that sets a header. Corvo reads the header as the identity.

For OSS, option 1 is sufficient. The UI stores the token in localStorage and sends it as a Bearer header on all API requests. Logging out clears the token.

---

## Enterprise: SSO + RBAC

Enterprise features are enabled by a signed license token validated with an Ed25519 public key.

### SSO (SAML / OIDC)

Current implementation:

- **OIDC**: bearer ID-token verification via issuer discovery/JWKS.
- **SAML**: trusted-header mode (`--saml-header-auth`) for deployments that terminate SAML at a proxy/IdP gateway.

Server flags:

```bash
corvo server \
  --license-key "$CORVO_LICENSE_KEY" \
  --license-public-key "$CORVO_LICENSE_PUBLIC_KEY" \
  --oidc-issuer-url "https://accounts.google.com" \
  --oidc-client-id "xxx.apps.googleusercontent.com"
```

### Dynamic API key management

API key CRUD is available in OSS and enterprise:

```
POST   /api/v1/auth/keys
GET    /api/v1/auth/keys
DELETE /api/v1/auth/keys
```

Create a key:

```json
POST /api/v1/auth/keys
{"name":"new-worker-pool","role":"worker","queue_scope":"emails.*","namespace":"production","expires_at":"2027-01-01T00:00:00Z"}
```

The key value is returned once on creation and never shown again. Keys are stored hashed (SHA-256) in the database.

Keys support:

- **Expiry** — key stops working after `expires_at`
- **Namespace scoping** — key is bound to a tenant namespace
- **Usage tracking** — last used timestamp
- **Revocation** — immediate, no restart required

### RBAC

Enterprise adds custom, fine-grained permissions:

```json
POST /api/v1/auth/roles
{
  "name": "queue-operator",
  "permissions": [
    { "resource": "queues", "actions": ["read", "pause", "resume", "drain"] },
    { "resource": "jobs", "actions": ["read", "retry", "cancel"] },
    { "resource": "jobs", "actions": ["approve", "reject"] }
  ]
}
```

Permission model:

```
resource: API top-level resource (`queues`, `jobs`, `budgets`, `auth`, ...)
actions:  `read`, `write`, `delete`, plus operation actions (`pause`, `resume`, `retry`, ...)
```

Roles are assigned to API keys:

```json
POST   /api/v1/auth/keys/{key_hash}/roles   {"role":"queue-operator"}
GET    /api/v1/auth/keys/{key_hash}/roles
DELETE /api/v1/auth/keys/{key_hash}/roles/{role}
```

Multiple roles can be assigned. Permissions are additive (union of all role permissions).

### Namespace scoping (multi-tenancy)

In Enterprise multi-tenant mode, every key and user belongs to a namespace. They can only see and operate on resources in their namespace. Admin keys with `namespace: "*"` can operate across all namespaces.

See [ENTERPRISE.md](./ENTERPRISE.md) for the full multi-tenancy design.

---

## Security considerations

- Keys are stored hashed (SHA-256) in SQLite; raw values are only returned on creation/update.
- Auth should be deployed behind TLS termination.
- `GET /healthz` stays unauthenticated for probes.

## Summary

| Feature | OSS | Enterprise (licensed) |
|---|---|---|
| API key auth (`X-API-Key`/Bearer) | Yes | Yes |
| Built-in roles (`admin`, `readonly`, `worker`, `operator`) | Yes | Yes |
| API key CRUD API | Yes | Yes |
| Namespace scoping | Yes | Yes |
| Audit logs | Yes | Yes |
| Key expiry (`expires_at`) | Yes | Yes |
| OIDC bearer auth | No | Yes (`sso`) |
| SAML trusted-header auth | No | Yes (`sso`) |
| Custom RBAC roles + role bindings | No | Yes (`rbac`) |
