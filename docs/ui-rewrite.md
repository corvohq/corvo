# UI Rewrite: React → HTMX

## Decision (2026-03-27)

Drop the React SPA and rewrite the UI using HTMX + server-rendered HTML from Zig.

## Why

The React UI (890KB JS bundle) cannot be served through the main server's send_buf
(~66KB, sized for RPC payloads). Attempted solutions and why they failed:

- **posix.write bypass**: Blocks the io_uring event loop, starves other connections
- **send_extra on ConnState**: Modifies the IO layer — violates TigerStyle (IO is sacred)
- **Separate UI server thread**: Works but adds complexity for no good reason
- **Code splitting + gzip**: Even split, React+ReactDOM alone is ~45KB gzipped,
  Recharts is ~65KB gzipped. Individual chunks still borderline or exceed send_buf
- **Preact swap**: Saves ~137KB but other deps (Recharts 393KB, Radix 43KB) remain

Root cause: the React ecosystem is too heavy for an embedded admin dashboard.
890KB bundle = 140KB React + 393KB Recharts + 43KB Radix + 100KB router/query/utils
+ ~200KB app code with deps. Actual application code is only ~6,800 lines / ~30KB minified.

## New Architecture

**HTMX + Tailwind CSS, server-rendered HTML from Zig.**

### How it works

- Zig renders HTML into send_buf (same pattern as json_writer.zig for JSON)
- HTMX (~14KB) handles dynamic interactions (hx-get, hx-post, hx-swap)
- Tailwind CSS (~41KB pre-built, 8KB gzipped) for styling
- Charts: server-generated SVG (zero JS chart library)
- SSE: native EventSource, server pushes HTML fragments
- Auth: cookie check server-side, redirect to login page
- All assets embedded via @embedFile, fits in send_buf trivially

### What to build (core pages only)

1. **Dashboard** — queue stats cards, recent failures table, SVG throughput chart
2. **Queues list** — table with stats, click to detail
3. **Queue detail** — job table, pause/resume/drain/clear/concurrency/throttle actions
4. **Dead letter** — dead jobs table, retry/delete/move actions
5. **Held jobs** — held jobs with approve/reject buttons
6. **Scheduled jobs** — scheduled jobs table, run-now action
7. **Job detail** — full job info, retry/cancel/delete/clone/move actions
8. **Workers** — connected workers table
9. **Cluster status** — node info, leader state

### Enterprise features

SSO, RBAC/roles, namespaces, audit logs, API keys, cost dashboard — these routes live in the
enterprise directory. They're just additional Zig route handlers compiled in (or not)
based on the build. Open-source builds simply don't include them. No feature flags,
no conditional UI rendering. The build boundary IS the feature boundary.

### Actions (hx-post)

All write actions use the existing HTTP API endpoints:
- Enqueue: `hx-post="/api/v1/enqueue"`
- Pause: `hx-post="/api/v1/queues/{name}/pause"`
- Retry: `hx-post="/api/v1/jobs/{id}/retry"`
- etc.

HTMX swaps in a success/error toast fragment after each action.

### Live updates

```html
<div hx-get="/ui/partials/dashboard-stats" hx-trigger="every 5s" hx-swap="innerHTML">
  <!-- server-rendered stats cards -->
</div>
```

Or via SSE:
```html
<div hx-ext="sse" sse-connect="/api/v1/events" sse-swap="job.completed">
  <!-- re-fetch on events -->
</div>
```

### File structure

```
ui_embed.zig              — @embedFile for htmx.min.js, tailwind.css, favicon
src/http_ui.zig           — UI route handlers (render HTML into send_buf)
src/html_writer.zig       — HTML builder (like json_writer.zig but for HTML)
ui/htmx.min.js            — HTMX library (~14KB)
ui/tailwind.css           — pre-built Tailwind CSS
ui/favicon.svg            — existing favicon
```

### Bundle size comparison

| Asset         | React SPA | HTMX rewrite | HTMX gzipped |
|---------------|-----------|--------------|--------------|
| JS            | 890 KB    | 51 KB        | 16 KB        |
| CSS           | 41 KB     | 13 KB        | 3.4 KB       |
| Total         | 931 KB    | 64 KB        | 19.4 KB      |
| Fits send_buf | No        | Yes          | Yes          |

### What stays

- `http.zig` — route classification (add /ui/* as read routes)
- `http_read.zig` — dispatch (add UI route handlers or delegate to http_ui.zig)
- `writeResponseHeader` in http.zig — useful for serving embedded assets
- All existing API endpoints — unchanged
- `gen_ui_embed.zig` — reuse for embedding htmx.min.js + tailwind.css
- Playwright e2e tests — update selectors but same test structure

### What goes

- `ui/` directory (React app, node_modules, package.json, vite config)
- React-specific global-setup.ts (no more Vite dev server)
- `build.zig` ui module wiring (replace with new embedded assets)

## Implementation order

### Done (2026-03-27)

1. ~~Create html_writer.zig (buffer-based HTML builder)~~
2. ~~Download htmx.min.js, pre-build tailwind.css, update ui_embed.zig~~
3. ~~Build layout/shell (sidebar nav, page template)~~
4. ~~Dashboard page (stats + SVG bar chart)~~
5. ~~Queues list + queue detail with basic actions~~
6. ~~Dead letter / held / scheduled pages with row actions~~
7. ~~Job detail page with retry/cancel/delete~~
8. ~~Workers + cluster pages~~
9. ~~Enqueue dialog (basic: queue + payload)~~
10. ~~Bulk actions (select-all + action bar)~~
11. ~~Update Playwright tests~~
12. ~~Delete React UI (80+ files, no more npm/node_modules)~~
13. ~~Pre-gzip static assets (htmx 16KB, tailwind 3.4KB gzipped)~~
14. ~~Match React color scheme (white sidebar, indigo active, clean cards)~~
15. ~~HTML templates refactor: layout.html with {{title}}/{{content}} placeholders,~~
    ~~renderPage() substitution, nav highlight via client-side JS~~
16. ~~Queue detail: stats bar (4 cards), filter tabs (all 7 states + All), client-side search~~

17. ~~Job detail: 2-column grid (properties + timeline), payload with copy button, error history~~

18. ~~Enqueue dialog: add priority, max retries, scheduled at, unique key fields~~
    ~~+ fixed form to submit JSON (was sending form-encoded, API expects JSON)~~
    ~~+ collapsible "Advanced Options" section with priority select, max retries, scheduled at, unique key~~
    ~~+ moved all pages to HTML templates with {{placeholder}} substitution~~
    ~~+ renderTemplate engine, 9 template files (layout, dashboard, queues, queue-detail,~~
    ~~  job-list, job-detail, workers, cluster, enqueue-form)~~
    ~~+ HtmlWriter only for dynamic content (table rows, stats, charts)~~

19. ~~Pagination on all job tables (prev/next, "Page X of Y", offset queries)~~
20. ~~Date formatting: `<time data-ts>` elements + JS relative timestamps ("1m ago")~~
21. ~~Job search/filters: queue dropdown on dead letter/held/scheduled pages,~~
    ~~state filter tabs on queue detail (already done in step 16)~~
22. Throughput chart — **deferred**: requires backend metrics/throughput endpoint
23. ~~Export: JSON/CSV buttons on all job tables (client-side fetch + download)~~
24. ~~Mobile responsive: hamburger menu, collapsible sidebar, scrollable tables~~
    ~~(done in step 17 commit, verified responsive classes on all templates)~~
