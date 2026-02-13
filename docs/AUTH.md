# Authentication & Authorization

Jobbie supports two auth tiers: static API key auth (OSS) and SSO + RBAC (Enterprise). Auth is optional — when disabled, all endpoints are open (development mode).

---

## Quick start

Enable auth by adding keys to the config:

```yaml
# jobbie.yaml
auth:
  enabled: true
  keys:
    - key: "jb_prod_abc123..."
      name: "production-workers"
      queues: ["*"]
      role: "worker"
    - key: "jb_prod_def456..."
      name: "admin-cli"
      queues: ["*"]
      role: "admin"
```

Or via environment variables:

```bash
JOBBIE_AUTH_ENABLED=true
JOBBIE_AUTH_KEYS='[{"key":"jb_prod_abc123...","name":"production-workers","queues":["*"],"role":"worker"}]'
```

Workers authenticate with a Bearer token:

```
POST /api/v1/fetch
Authorization: Bearer jb_prod_abc123...
Content-Type: application/json

{"queues": ["emails.send"], "worker_id": "worker-1"}
```

CLI:

```bash
export JOBBIE_TOKEN=jb_prod_def456...
jobbie queues
```

---

## OSS: Static API key auth

API keys are defined in the server config file or environment variables. No database, no CRUD API, no key management UI. Add or remove keys by updating the config and restarting the server.

### Key format

Keys should be generated with sufficient entropy (32+ bytes, base62 encoded). Convention: prefix with `jb_` and an environment hint for easy identification.

```
jb_prod_a1b2c3d4e5f6...    # production
jb_dev_x9y8z7w6v5u4...     # development
jb_test_m3n4o5p6q7r8...    # testing
```

Jobbie does not generate keys — you generate them yourself and put them in the config. Example:

```bash
openssl rand -base64 32 | tr -d '=/+' | sed 's/^/jb_prod_/'
```

### Configuration

```yaml
auth:
  enabled: true
  keys:
    - key: "jb_prod_abc123..."
      name: "email-workers"          # human-readable label (for logging)
      queues: ["emails.*"]           # glob patterns for queue access
      role: "worker"

    - key: "jb_prod_def456..."
      name: "payment-workers"
      queues: ["payments.*"]
      role: "worker"

    - key: "jb_prod_ghi789..."
      name: "ops-team"
      queues: ["*"]
      role: "admin"

    - key: "jb_prod_jkl012..."
      name: "dashboard-readonly"
      queues: ["*"]
      role: "readonly"
```

### Roles

Three built-in roles. No custom roles in OSS — use Enterprise RBAC for that.

| Role | Permissions |
|---|---|
| `worker` | enqueue, fetch, ack, fail, heartbeat, progress, batch enqueue, batch ack |
| `readonly` | search, get job, list queues, list workers, list budgets, usage summary, SSE events, UI read access |
| `admin` | everything: all worker permissions, all read permissions, plus queue management (pause, resume, drain, clear, delete, concurrency, throttle), job management (retry, cancel, hold, approve, reject, delete, move, replay), bulk operations, budget management, cluster admin |

The `worker` role is intentionally limited. Workers can enqueue and process jobs but cannot pause queues, retry dead jobs, or approve held jobs. This follows the principle of least privilege — a compromised worker token cannot disrupt queue operations.

### Queue scoping

The `queues` field accepts glob patterns:

```yaml
queues: ["*"]                    # all queues
queues: ["emails.*"]             # emails.send, emails.bulk, etc.
queues: ["emails.send"]          # only emails.send
queues: ["emails.*", "sms.*"]    # emails and sms queues
queues: ["ai.agents.*"]          # all AI agent queues
```

Queue scoping is enforced on all operations:

- **fetch** — can only fetch from matching queues
- **enqueue** — can only enqueue to matching queues
- **search** — results filtered to matching queues
- **queue management** — can only pause/resume/etc. matching queues
- **job operations** — can only retry/cancel/approve jobs in matching queues

A `readonly` key with `queues: ["emails.*"]` can only see email jobs in search results and the UI.

### Auth disabled (development mode)

When `auth.enabled` is false (the default), all requests are treated as admin with access to all queues. This is the development mode — no tokens required.

The server logs a warning on startup:

```
WARN auth disabled — all endpoints are open. Set auth.enabled=true for production.
```

### Auth on the UI

When auth is enabled, the UI requires a token. Options:

1. **Login page** — enter an API key, stored in localStorage. Simple, works for small teams.
2. **Proxy auth** — put Jobbie behind an authenticating reverse proxy (nginx, Cloudflare Access, etc.) that sets a header. Jobbie reads the header as the identity.

For OSS, option 1 is sufficient. The UI stores the token in localStorage and sends it as a Bearer header on all API requests. Logging out clears the token.

---

## Enterprise: SSO + RBAC

Enterprise auth replaces static API keys with identity provider integration and fine-grained permissions. Enabled by license key.

### SSO (SAML / OIDC)

Authenticate users against an external identity provider:

```yaml
auth:
  enabled: true
  sso:
    provider: "oidc"
    issuer: "https://accounts.google.com"
    client_id: "xxx.apps.googleusercontent.com"
    client_secret: "GOCSPX-xxx"
    redirect_uri: "https://jobbie.example.com/auth/callback"
    allowed_domains: ["example.com"]
```

Supported providers:

- **OIDC** — Google, Azure AD, Okta, Auth0, any OIDC-compliant provider
- **SAML 2.0** — for enterprises that require SAML

SSO is for the UI and management API. Workers still use API keys (machines don't do SSO). The enterprise tier adds a key management API so keys can be created/revoked dynamically instead of living in a config file.

### Dynamic API key management

Enterprise adds CRUD endpoints for API keys:

```
POST   /api/v1/auth/keys              — create a key
GET    /api/v1/auth/keys              — list all keys
DELETE /api/v1/auth/keys/{id}         — revoke a key
```

Create a key:

```json
POST /api/v1/auth/keys
{
  "name": "new-worker-pool",
  "role": "worker",
  "queues": ["emails.*"],
  "namespace": "production",
  "expires_at": "2027-01-01T00:00:00Z"
}

-> 201 Created
{
  "id": "key_01HX...",
  "key": "jb_prod_abc123...",
  "name": "new-worker-pool",
  "created_at": "2026-02-12T10:00:00Z"
}
```

The key value is returned once on creation and never shown again. Keys are stored hashed (SHA-256) in the database.

Enterprise keys support:

- **Expiry** — key stops working after `expires_at`
- **Namespace scoping** — key is bound to a tenant namespace
- **Usage tracking** — last used timestamp, request count
- **Revocation** — immediate, no restart required

### RBAC

Enterprise replaces the three fixed roles with custom, fine-grained permissions:

```json
POST /api/v1/auth/roles
{
  "name": "queue-operator",
  "permissions": [
    { "resource": "queues/*", "actions": ["read", "pause", "resume", "drain"] },
    { "resource": "jobs/*", "actions": ["read", "retry", "cancel"] },
    { "resource": "jobs/*", "actions": ["approve", "reject"], "queues": ["ai.*"] }
  ]
}
```

Permission model:

```
resource: "queues/*" | "queues/emails.*" | "jobs/*" | "budgets/*" | "cluster/*" | ...
actions:  "read" | "write" | "pause" | "resume" | "retry" | "cancel" | "approve" | ...
queues:   optional queue glob filter (defaults to all queues the key can access)
```

Roles are assigned to API keys or SSO users:

```json
POST /api/v1/auth/keys
{
  "name": "email-operator",
  "roles": ["queue-operator"],
  "queues": ["emails.*"],
  "namespace": "production"
}
```

Multiple roles can be assigned. Permissions are additive (union of all role permissions).

### Namespace scoping (multi-tenancy)

In Enterprise multi-tenant mode, every key and user belongs to a namespace. They can only see and operate on resources in their namespace. Admin keys with `namespace: "*"` can operate across all namespaces.

See [ENTERPRISE.md](./ENTERPRISE.md) for the full multi-tenancy design.

---

## Implementation

### Interface

```go
// internal/server/auth.go

type Identity struct {
    Name      string   // "email-workers" or "jeremy@example.com"
    Role      string   // "worker", "readonly", "admin" (OSS) or custom role (Enterprise)
    Queues    []string // glob patterns: ["emails.*"]
    Namespace string   // "default" (OSS) or tenant namespace (Enterprise)
}

type AuthProvider interface {
    // Authenticate extracts and validates credentials from the request.
    // Returns ErrNoCredentials if no auth header present.
    // Returns ErrInvalidKey if credentials are invalid.
    Authenticate(r *http.Request) (*Identity, error)

    // Authorize checks if the identity can perform the action on the resource.
    // Returns ErrForbidden if not allowed.
    Authorize(id *Identity, resource, action string) error
}
```

### OSS implementation (static API keys)

```go
// internal/server/auth_static.go

type staticAuth struct {
    keys map[string]*APIKey // key string -> config, loaded at startup
}

func NewStaticAuth(cfg AuthConfig) *staticAuth {
    keys := make(map[string]*APIKey, len(cfg.Keys))
    for _, k := range cfg.Keys {
        keys[k.Key] = &k
    }
    return &staticAuth{keys: keys}
}

func (a *staticAuth) Authenticate(r *http.Request) (*Identity, error) {
    token := extractBearer(r)
    if token == "" {
        return nil, ErrNoCredentials
    }
    key, ok := a.keys[token]
    if !ok {
        return nil, ErrInvalidKey
    }
    return &Identity{
        Name:      key.Name,
        Role:      key.Role,
        Queues:    key.Queues,
        Namespace: "default",
    }, nil
}

func (a *staticAuth) Authorize(id *Identity, resource, action string) error {
    if !roleAllows(id.Role, action) {
        return ErrForbidden
    }
    if !queueGlobMatch(id.Queues, resource) {
        return ErrForbidden
    }
    return nil
}
```

### No auth (development mode)

```go
// internal/server/auth_noop.go

type noopAuth struct{}

func (noopAuth) Authenticate(*http.Request) (*Identity, error) {
    return &Identity{Name: "anonymous", Role: "admin", Queues: []string{"*"}}, nil
}

func (noopAuth) Authorize(*Identity, string, string) error {
    return nil
}
```

### Enterprise implementation

```go
// internal/enterprise/auth.go

type enterpriseAuth struct {
    db       *sql.DB        // dynamic keys + roles stored in DB
    oidc     *oidc.Provider // SSO provider
    saml     *saml.SP       // SAML service provider
    cache    *lru.Cache     // key lookup cache (avoid DB hit per request)
}

func (a *enterpriseAuth) Authenticate(r *http.Request) (*Identity, error) {
    // 1. Check Bearer token (API key) — for workers and CLI
    if token := extractBearer(r); token != "" {
        return a.authenticateAPIKey(token)
    }
    // 2. Check SSO session cookie — for UI users
    if session := extractSession(r); session != "" {
        return a.authenticateSession(session)
    }
    return nil, ErrNoCredentials
}

func (a *enterpriseAuth) Authorize(id *Identity, resource, action string) error {
    // Load roles for identity, check permissions against resource + action
    // Permissions are additive across all assigned roles
}
```

### Middleware wiring

```go
func (s *Server) buildRouter() chi.Router {
    r := chi.NewRouter()

    // Global auth middleware (runs on every request)
    r.Use(s.authMiddleware)

    r.Route("/api/v1", func(r chi.Router) {
        // Read endpoints — require "read" action
        r.With(s.requireAction("read")).Get("/queues", s.handleListQueues)
        r.With(s.requireAction("read")).Get("/jobs/{id}", s.handleGetJob)
        // ...

        // Write endpoints — require specific actions
        r.With(s.requireAction("enqueue")).Post("/enqueue", s.handleEnqueue)
        r.With(s.requireAction("approve")).Post("/jobs/{id}/approve", s.handleApproveJob)
        // ...
    })
}

func (s *Server) authMiddleware(next http.Handler) http.Handler {
    return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
        identity, err := s.auth.Authenticate(r)
        if err != nil {
            writeError(w, 401, "unauthorized", "AUTH_ERROR")
            return
        }
        ctx := context.WithValue(r.Context(), identityKey, identity)
        next.ServeHTTP(w, r.WithContext(ctx))
    })
}

func (s *Server) requireAction(action string) func(http.Handler) http.Handler {
    return func(next http.Handler) http.Handler {
        return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
            id := identityFromContext(r.Context())
            resource := extractResource(r) // e.g. "queues/emails.send" from URL
            if err := s.auth.Authorize(id, resource, action); err != nil {
                writeError(w, 403, "forbidden", "FORBIDDEN")
                return
            }
            next.ServeHTTP(w, r)
        })
    }
}
```

### Startup selection

```go
func New(s *store.Store, cluster ClusterInfo, cfg Config) *Server {
    srv := &Server{store: s, cluster: cluster}

    if cfg.Auth.Enabled {
        lic := enterprise.ValidateLicense(cfg.LicenseKey)
        if lic != nil && lic.HasFeature("sso") {
            srv.auth = enterprise.NewAuth(s, cfg.Auth)
            slog.Info("enterprise auth enabled (SSO + RBAC)")
        } else {
            srv.auth = NewStaticAuth(cfg.Auth)
            slog.Info("auth enabled (static API keys)", "keys", len(cfg.Auth.Keys))
        }
    } else {
        srv.auth = noopAuth{}
        slog.Warn("auth disabled — all endpoints are open")
    }

    srv.router = srv.buildRouter()
    return srv
}
```

---

## Security considerations

### Key storage

- OSS: keys live in the config file. Protect the file with filesystem permissions. In Kubernetes, use a Secret mounted as a file or env var.
- Enterprise: keys are stored hashed (SHA-256) in SQLite. The raw key is returned once on creation and never retrievable again.

### Transport security

Auth without TLS is pointless — tokens are visible on the wire. Production deployments should terminate TLS at a reverse proxy (nginx, Caddy, cloud load balancer) or use Jobbie's built-in TLS (when implemented).

### Rate limiting on auth failures

To prevent brute-force key guessing, the auth middleware tracks failed attempts by IP. After 10 failures in 60 seconds, subsequent requests from that IP receive `429 Too Many Requests` for 5 minutes. This is built into the OSS auth middleware.

### UI token storage

The UI stores the API key in localStorage. This is acceptable for an admin dashboard (same security model as Grafana, Kibana, etc.). The token is sent as a Bearer header, never as a cookie (avoids CSRF). Logging out clears localStorage.

### Healthz endpoint

`GET /healthz` is always unauthenticated. Load balancers and Kubernetes probes need it to work without credentials.

---

## Summary

| Feature | OSS | Enterprise |
|---|---|---|
| Auth disabled (dev mode) | Yes | Yes |
| Static API keys from config | Yes | Yes |
| Three built-in roles (worker/readonly/admin) | Yes | Yes |
| Queue glob scoping on keys | Yes | Yes |
| Auth failure rate limiting | Yes | Yes |
| SSO (OIDC / SAML) | No | Yes |
| Dynamic key management API | No | Yes |
| Key expiry and revocation | No | Yes |
| Custom RBAC roles | No | Yes |
| Namespace-scoped keys | No | Yes |
| Key usage tracking | No | Yes |
