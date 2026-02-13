# Enterprise & Cloud Strategy

How Jobbie separates OSS from paid features, enforces licensing, and ships a single binary for both tiers.

---

## Guiding principle

**OSS = everything a single team needs to run in production.**
**Paid = everything an organization with multiple teams needs, plus not running it yourself.**

Don't gate features that individual developers need. Gate operational complexity and governance. If a developer hits a paywall during evaluation, they leave. The OSS must be genuinely complete — that's what drives adoption, and adoption is what drives enterprise sales.

Faktory gates batches, progress tracking, unique jobs, and throttling behind $149-949/month. We give away every processing feature for free and charge for the things that only matter at organizational scale.

---

## Feature split

### Free (OSS)

Everything that touches job processing:

- Full job lifecycle (enqueue, fetch, ack, fail, retry, cancel, move, delete)
- All queue management (pause, resume, drain, clear, concurrency, throttle)
- All AI features (agent loop, iterations, budgets, cost tracking, held jobs, approval policies)
- Caching, replay, search, bulk operations
- Clustering / HA (up to 3 nodes)
- The entire UI
- All client SDKs (Go, Python, TypeScript, Rust, etc.)
- Prometheus / OpenTelemetry metrics
- CLI
- Cron / scheduled jobs
- Basic webhooks (fire-and-forget POST on job lifecycle events)
- API key auth with queue-scoped globs and three built-in roles (see [AUTH.md](./AUTH.md))
- Basic health indicators in the UI

### Cloud (managed hosting — priced by throughput)

Everything in OSS, plus:

- Zero-ops managed Jobbie — no Raft clusters to run
- Auto-scaling (node count adapts to throughput)
- Global regions (deploy close to workers)
- Automated backups with point-in-time recovery
- Uptime SLA
- Email support

### Enterprise (self-hosted or cloud add-on — annual contract)

Everything in Cloud, plus:

| Feature | Why it's paid |
|---|---|
| Multi-tenancy / namespaces | Single team doesn't need isolation from itself |
| SSO (SAML / OIDC) | Single team uses API keys; SSO is an IT/compliance requirement (see [AUTH.md](./AUTH.md)) |
| RBAC | Per-namespace, per-queue permissions. Single team gives everyone admin (see [AUTH.md](./AUTH.md)) |
| Audit log | "Who approved that held job?" — compliance requirement |
| Encryption at rest | Regulatory/compliance (SOC2, HIPAA) |
| Extended retention | OSS keeps 7 days default; enterprise wants 90+ days with full-text search |
| Custom retention policies | Per-queue, per-state rules |
| Advanced webhooks | Delivery tracking, retry policies, signature verification, delivery guarantees |
| Advanced alerting | Configurable alert rules with routing, escalation, PagerDuty/Slack integration |
| Advanced analytics | Cost forecasting, trend analysis, custom report builder |
| Cross-region replication | Disaster recovery for critical workloads |
| Dedicated support + SLA | Contractual response time guarantees |
| SOC2 compliance | Certification and documentation |

### Gray area decisions

**Webhooks**: Basic (fire-and-forget POST) = OSS. Reliable delivery with retries, DLQ, signature verification, delivery dashboard = paid.

**Alerting**: Health indicators in UI (queue depth trending, error spikes) = OSS. Configurable rules with routing, escalation, integrations = paid.

**Analytics**: Usage summary endpoint and cost dashboard = OSS. Forecasting, trend analysis, scheduled reports = paid.

**Approval policies**: Basic conditions (cost, queue, action type) = OSS. Dry-run mode, policy-hit diagnostics, policy versioning, escalation chains = paid.

---

## Architecture: interfaces + license key, single binary

One binary. All code compiles in. Enterprise features are behind Go interfaces with no-op defaults. A license key unlocks them at runtime.

```
jobbie server                              -> OSS mode
jobbie server --license-key=ent_abc123     -> enterprise features unlock
JOBBIE_LICENSE_KEY=ent_abc123 jobbie server -> same, via env var
```

### Why not alternatives

| Approach | Verdict | Reason |
|---|---|---|
| Microservices | No | Destroys single-binary value prop. "Zero dependencies" becomes "run 5 services plus a service mesh." |
| Build tags / two binaries | No | Doubles maintenance and test matrix. Trivially bypassed (just build with the tag). GitLab tried CE/EE split, eventually merged them. |
| Go plugins | No | Broken in practice. Must be compiled with exact same Go version and dependency tree. One mismatch = panic at load. |
| Separate enterprise repo | No | Merge hell. Every interface change in OSS needs corresponding update in enterprise repo. |
| **Interfaces + license key** | **Yes** | One binary, clean code, runtime unlock. What HashiCorp, Grafana, and most successful OSS-to-enterprise Go projects do. |

### Interface pattern

Define interfaces in the core server for every enterprise hook point:

```go
// internal/server/enterprise.go

type AuthProvider interface {
    Authenticate(r *http.Request) (*Identity, error)
    Authorize(id *Identity, resource, action string) error
}

type AuditLogger interface {
    Log(event AuditEvent)
}

type TenantResolver interface {
    Resolve(r *http.Request) (namespace string, err error)
}
```

OSS defaults — always pass, never log, single namespace:

```go
type noopAuth struct{}
func (noopAuth) Authenticate(*http.Request) (*Identity, error) {
    return &Identity{Role: "admin"}, nil
}
func (noopAuth) Authorize(*Identity, string, string) error { return nil }

type noopAudit struct{}
func (noopAudit) Log(AuditEvent) {}

type noopTenant struct{}
func (noopTenant) Resolve(*http.Request) (string, error) { return "default", nil }
```

The server always calls through the interface:

```go
func (s *Server) requireAuth(next http.Handler) http.Handler {
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
```

In OSS mode, `s.auth` is `noopAuth{}` — every request is "admin", every action is authorized. Zero overhead. The middleware runs identically in both modes; only the implementation changes.

### Wiring up at startup

```go
func New(s *store.Store, cluster ClusterInfo, opts ...Option) *Server {
    srv := &Server{
        // OSS defaults
        auth:   noopAuth{},
        audit:  noopAudit{},
        tenant: noopTenant{},
    }

    // If valid license, swap in enterprise implementations
    if lic := enterprise.ValidateLicense(opts.LicenseKey); lic != nil {
        if lic.HasFeature("auth")    { srv.auth = enterprise.NewAuth(s) }
        if lic.HasFeature("audit")   { srv.audit = enterprise.NewAuditLogger(s) }
        if lic.HasFeature("tenancy") { srv.tenant = enterprise.NewTenantResolver(s) }
        slog.Info("enterprise features enabled", "features", lic.Features())
    }

    srv.router = srv.buildRouter()
    return srv
}
```

### Directory structure

```
jobbie/
├── internal/
│   ├── server/              # core (uses interfaces)
│   ├── store/               # core
│   ├── raft/                # core
│   └── enterprise/          # enterprise implementations
│       ├── license.go       # license key validation (Ed25519 signed JWT)
│       ├── auth.go          # API key + OIDC/SAML auth
│       ├── rbac.go          # per-namespace, per-queue permissions
│       ├── audit.go         # audit event logging
│       ├── tenancy.go       # namespace isolation, request scoping
│       ├── encryption.go    # encryption at rest for payloads
│       ├── retention.go     # configurable retention policies
│       ├── webhooks.go      # reliable webhook delivery with retries
│       └── analytics.go     # advanced cost analytics, forecasting
```

No build tags. No separate binaries. No conditional compilation. One binary, interface dispatch.

---

## License key design

### Format

Signed JWT (Ed25519):

```json
{
  "customer": "acme-corp",
  "tier": "enterprise",
  "features": ["auth", "rbac", "audit", "tenancy", "encryption"],
  "max_nodes": 7,
  "expires": "2027-02-12T00:00:00Z"
}
```

Signed with our private key (stays on the signing server). Verified with a public key embedded in the binary.

### Properties

- **No phone-home required** — air-gapped deployments must work. The binary validates the signature locally against the embedded public key.
- **Unforgeable** — they can't change the expiry or features without our private key. Modifying any field invalidates the signature.
- **Grace period on expiry** — log `WARN enterprise license expired, enterprise features will be disabled in 7 days`. Don't break production. Make paying easy, not piracy hard.
- **Clear logging** — on startup, log which features are enabled and when the license expires.

### Optional phone-home (opt-in telemetry)

If they opt in, the binary sends a periodic heartbeat to our server:

- Node count, feature usage, version
- Lets us detect if a single license key appears on 50 clusters
- Strictly opt-in — never required for functionality

### What we don't do

- **Phone-home required** — kills air-gapped deployments, enterprises hate it
- **Binary obfuscation** — wastes our time, determined people bypass it anyway
- **Feature time-bombs** — breaks production, creates enemies
- **Hardware fingerprinting** — nightmare for container/k8s deployments

### Can enterprises tamper with it?

The JWT signature prevents modification. But a determined engineer could patch the binary to skip validation entirely. This is true of every commercial OSS product (HashiCorp, Grafana, Elastic).

It doesn't matter because:

1. **Enterprises don't tamper with licenses.** Companies with procurement processes and SOC2 audits don't commit license fraud. The legal risk far outweighs the cost of paying.
2. **The license key isn't the enforcement — the contract is.** If they tamper, that's breach of contract. The key is a speed bump, not DRM.
3. **They need what they can't pirate.** Updates, security patches, support, SLA guarantees, and the Cloud offering. A tampered binary gets none of those.

---

## Source code visibility

### Options considered

**Option A: Fully open source, license-enforced**

Everything in one public repo. Enterprise code visible but license-gated at runtime.

- Pros: Maximum trust. Enterprises can audit RBAC/encryption before buying. Security researchers review your code. Contributors fix bugs in enterprise features.
- Cons: A competitor could fork it (but maintaining a fork is expensive and you're always behind upstream).
- Who does this: Grafana.

**Option B: Open core, enterprise in private repo**

OSS code is public. Enterprise code in a separate private repo that imports OSS as a Go module. Enterprise binary is a superset.

- Pros: Enterprise code is truly proprietary. Competitors can't see implementation details.
- Cons: Merge hell — every interface change in OSS needs corresponding update in enterprise repo. Two repos, two CI pipelines.
- Who does this: HashiCorp (pre-2023), early GitLab.

**Option C: Source-available with usage restrictions (recommended)**

Everything in one public repo. The `enterprise/` directory has a different license (BSL 1.1).

```
jobbie/
├── LICENSE                 <- Apache 2.0 (covers everything except enterprise/)
├── internal/
│   ├── server/             <- Apache 2.0
│   ├── store/              <- Apache 2.0
│   ├── raft/               <- Apache 2.0
│   └── enterprise/
│       ├── LICENSE          <- BSL 1.1 (converts to Apache 2.0 after 3 years)
│       └── ...
```

- Pros: Code is visible (auditable, trustworthy) AND legally protected. One repo, one CI pipeline, no merge hell. Enterprise buyers can read the code before purchasing.
- Cons: BSL scares some open-source purists. Some companies have policies against BSL software.
- Who does this: CockroachDB, HashiCorp (post-2023), Sentry, MariaDB, Elastic.

### Recommendation: Option C

The BSL with a 3-year conversion to Apache 2.0 is now industry-standard. Enterprise features are commercially protected during the period that matters. The community gets everything eventually. Enterprises can audit the code before buying. One repo, one binary, no merge hell.

Nobody can take the enterprise code and compete commercially. Everyone can read it, audit it, and contribute fixes. After 3 years, it becomes fully open source — by which point we've shipped 3 years of new enterprise features under the same rolling window.

---

## Cloud architecture

The Cloud offering is a separate concern from the Jobbie binary. The binary running inside Cloud is the same enterprise binary. What's separate is the control plane:

```
Cloud control plane (separate codebase, our infrastructure):
├── Provisioning    — spin up/down Jobbie clusters per customer
├── Billing         — usage metering, Stripe integration
├── API gateway     — tenant routing, rate limiting
├── Backup service  — scheduled snapshots to S3/GCS
└── Dashboard       — customer-facing management console

Jobbie binary (same enterprise binary, per-tenant):
└── jobbie server --license-key=cloud_internal_xxx
```

The control plane is a separate codebase with separate services — it's the platform that runs Jobbie, not part of Jobbie itself. This is where microservices make sense, because provisioning and billing genuinely are different concerns from job processing.

---

## Pricing page structure

**OSS (free forever)**
- Unlimited jobs, queues, workers
- Full AI features (agent loop, budgets, cost tracking, held jobs)
- Clustering (up to 3 nodes)
- UI, CLI, all SDKs
- API key auth with queue scoping and built-in roles ([AUTH.md](./AUTH.md)), basic webhooks
- Prometheus / OpenTelemetry metrics
- Community support

**Cloud ($X/mo based on throughput)**
- Everything in OSS
- Managed hosting, zero ops
- Auto-scaling, global regions
- Automated backups
- Uptime SLA
- Email support

**Enterprise ($Y/mo or annual contract)**
- Everything in Cloud
- Multi-tenancy / namespaces
- SSO + RBAC
- Audit logging
- Encryption at rest
- Extended retention
- Advanced webhooks, alerting, analytics
- Dedicated support + SLA
- SOC2 compliance
