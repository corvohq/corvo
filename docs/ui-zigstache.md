# UI Migration: HtmlWriter → zigstache

Replace HtmlWriter-based rendering with zigstache Mustache templates.
Move HTML out of Zig into .html files so the UI can be visually iterated.

## Design Reference

Match the **shadcn/ui** visual style from the previous React+Radix UI.
This is purely Tailwind — no React/Radix needed. Key patterns:

**Color palette**: zinc/slate base, not gray. `bg-zinc-950` sidebar, `bg-white` cards, `border-zinc-200` borders.

**Cards**: `rounded-xl border border-zinc-200 bg-white shadow-sm`

**Buttons**:
- Default: `bg-zinc-900 text-white hover:bg-zinc-800 rounded-md px-4 py-2 text-sm font-medium`
- Destructive: `bg-red-500 text-white hover:bg-red-600`
- Outline: `border border-zinc-200 bg-white hover:bg-zinc-100`
- Ghost: `hover:bg-zinc-100 rounded-md px-3 py-2`

**Badges**: `rounded-full px-2.5 py-0.5 text-xs font-medium` (not `rounded` — full pill)

**Tables**: `divide-y divide-zinc-200` rows, `text-sm text-zinc-500` headers, no visible borders

**Typography**: `text-zinc-900` primary, `text-zinc-500` secondary, `text-sm` body, `tracking-tight` headings

**Sidebar**: Dark (`bg-zinc-950 text-zinc-400`), active item `bg-zinc-800 text-white`, rounded items

**Spacing**: Generous — `p-6` cards, `gap-4` grids, `space-y-1` nav items

## Bug Fixes

- **Mobile menu**: Shows on desktop. Should only appear on `md:hidden`. Fix in layout.html.
- **Visual quality**: Current Tailwind classes are too basic (gray-800, minimal spacing, no shadows).

## Approach

### Step 1: Add zigstache dependency

Add to `build.zig.zon` and `build.zig`. Import in `http_ui.zig`.

### Step 2: Replace renderTemplate() with zigstache

- Parse each template at comptime: `const tmpl = comptime zigstache.Template.parse(ui_embed.dashboard_html) catch unreachable;`
- Replace `renderTemplate()` calls with `tmpl.render(&buf, data_struct)`
- Remove the old `renderTemplate()` function

### Step 3: Migrate pages (one at a time)

For each page, the process is:
1. Move HtmlWriter-generated HTML into the .html template using Mustache sections/loops
2. Create a data struct with the values the template needs
3. Remove the HtmlWriter code
4. Update Tailwind classes to match shadcn style

#### Page order (least to most complex):

**3a. cluster.html** — Already static, just update styling.

**3b. workers.html** — Simple table.
```mustache
{{#workers}}
<tr>
  <td>{{id}}</td>
  <td>{{hostname}}</td>
  <td>{{queues}}</td>
  <td><time data-ts="{{last_heartbeat}}">{{last_heartbeat_fmt}}</time></td>
</tr>
{{/workers}}
{{^workers}}
<tr><td colspan="4" class="text-center text-zinc-500 py-8">No workers connected</td></tr>
{{/workers}}
```

**3c. queues.html** — Table with status badges.
```mustache
{{#queues}}
<tr>
  <td><a href="/ui/queues/{{name}}">{{name}}</a></td>
  <td>{{pending}}</td>
  <td>{{active}}</td>
  <td>{{dead}}</td>
  <td>{{{status_badge}}}</td>
</tr>
{{/queues}}
```

**3d. dashboard.html** — Stats cards + chart + tables.
```mustache
<div class="grid grid-cols-2 lg:grid-cols-5 gap-4">
  {{#stats}}
  <div class="rounded-xl border border-zinc-200 bg-white shadow-sm p-6">
    <div class="text-sm font-medium text-zinc-500">{{label}}</div>
    <div class="mt-2 text-2xl font-semibold tracking-tight text-zinc-900">{{value}}</div>
  </div>
  {{/stats}}
</div>
```

**3e. job-list.html** — Shared template for dead-letter, held, scheduled pages.

**3f. queue-detail.html** — Stats bar, filter tabs, job table, pagination.

**3g. job-detail.html** — Properties, timeline, payload, errors.

### Step 4: Fix layout.html

- Restyle sidebar to dark theme (zinc-950)
- Fix mobile menu toggle (md:hidden only)
- Update header, buttons, modal styling
- Keep all existing JavaScript as-is

### Step 5: Restyle enqueue-form.html

Update to match shadcn form/input styles:
- Inputs: `rounded-md border border-zinc-300 px-3 py-2 text-sm focus:ring-2 focus:ring-zinc-900`
- Labels: `text-sm font-medium text-zinc-700`

## Data Structs

Each page needs a Zig struct that the template renders. Example for queue detail:

```zig
const QueueDetailData = struct {
    queue_name: []const u8,
    is_active: bool,
    is_paused: bool,
    pending: i64,
    active: i64,
    dead: i64,
    completed: i64,
    filters: []const FilterTab,
    jobs: []const JobRow,
    page: i32,
    total_pages: i32,
    has_prev: bool,
    has_next: bool,
};

const FilterTab = struct {
    label: []const u8,
    state: []const u8,
    count: i64,
    is_active: bool,
};

const JobRow = struct {
    id: []const u8,
    queue: []const u8,
    state: []const u8,
    state_class: []const u8,
    priority: i32,
    attempt: i32,
    created_ts: []const u8,
};
```

## Constraints

- **Buffer limits**: send_buf 66KB, page_buf 32KB — unchanged
- **IO layer**: Do NOT modify for UI concerns
- **JavaScript**: Keep all existing JS in layout.html — it works, don't rewrite
- **HTMX partials**: Must still work — partials render without layout wrapper
- **Comptime parsing**: All templates parsed at comptime via `@embedFile`

## What NOT to do

- Don't add npm, node_modules, or any JS build step
- Don't modify the IO layer or HTTP server
- Don't rewrite the JavaScript — just update HTML/Tailwind
- Don't add new dependencies besides zigstache
- Don't change the API endpoints or query parameter handling
