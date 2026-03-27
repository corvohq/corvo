//! corvo-inspect — read-only CLI for inspecting talon KV data.
//!
//! Opens the DB in read-only mode and decodes values using corvo's codec.
//! Does NOT take a write lock — safe to run against a live server.
//!
//! Usage:
//!   corvo-inspect <data-dir> get <key>
//!   corvo-inspect <data-dir> scan <prefix>
//!   corvo-inspect <data-dir> job <id>
//!   corvo-inspect <data-dir> count <prefix>

const std = @import("std");
const talon = @import("talon");
const corvo = @import("corvo");

const codec = corvo.codec;
const keys = corvo.keys;
const types = corvo.types;
const kv = corvo.kv;

const print = std.debug.print;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    if (args.len < 3) {
        printUsage();
        std.process.exit(1);
    }

    const data_dir = args[1];
    const cmd = args[2];

    const db = talon.DB.open(allocator, data_dir, .{}) catch |err| {
        print("error: cannot open DB at {s}: {}\n", .{ data_dir, err });
        std.process.exit(1);
    };
    defer db.close();

    var store = kv.Store.init(db);

    if (std.mem.eql(u8, cmd, "get")) {
        if (args.len < 4) {
            print("usage: corvo-inspect <data-dir> get <key>\n", .{});
            std.process.exit(1);
        }
        cmdGet(&store, args[3]);
    } else if (std.mem.eql(u8, cmd, "scan")) {
        if (args.len < 4) {
            print("usage: corvo-inspect <data-dir> scan <prefix>\n", .{});
            std.process.exit(1);
        }
        cmdScan(&store, args[3]);
    } else if (std.mem.eql(u8, cmd, "job")) {
        if (args.len < 4) {
            print("usage: corvo-inspect <data-dir> job <id>\n", .{});
            std.process.exit(1);
        }
        cmdJob(&store, args[3]);
    } else if (std.mem.eql(u8, cmd, "count")) {
        if (args.len < 4) {
            print("usage: corvo-inspect <data-dir> count <prefix>\n", .{});
            std.process.exit(1);
        }
        cmdCount(&store, args[3]);
    } else {
        print("unknown command: {s}\n", .{cmd});
        printUsage();
        std.process.exit(1);
    }
}

// ============================================================================
// Commands
// ============================================================================

fn cmdGet(store: *kv.Store, key: []const u8) void {
    var batch = store.newBatch();
    defer batch.close();

    var buf: [64 * 1024]u8 = undefined;
    if (batch.getInto(key, &buf)) |val| {
        print("key: {s}\n", .{key});
        printDecodedValue(key, val);
    } else {
        print("not found: {s}\n", .{key});
        std.process.exit(1);
    }
}

fn cmdScan(store: *kv.Store, prefix: []const u8) void {
    var end_buf: [keys.max_key_len]u8 = undefined;
    const end = incrementPrefix(prefix, &end_buf) orelse {
        print("error: invalid prefix\n", .{});
        std.process.exit(1);
    };

    var batch = store.newBatch();
    defer batch.close();

    var iter = batch.newIter(prefix, end);
    defer iter.close();

    var count: usize = 0;
    var valid = iter.first();
    while (valid) {
        const k = iter.key();
        const v = iter.value();

        if (count > 0) print("\n", .{});
        print("key: ", .{});
        printKeyReadable(k);
        print("\n", .{});
        printDecodedValue(k, v);
        count += 1;

        valid = iter.next();
    }

    if (count == 0) {
        print("no keys with prefix: {s}\n", .{prefix});
    } else {
        print("\n({d} keys)\n", .{count});
    }
}

fn cmdJob(store: *kv.Store, id: []const u8) void {
    var key_buf: [keys.max_key_len]u8 = undefined;
    const prefix = keys.prefix_job;
    @memcpy(key_buf[0..prefix.len], prefix);
    @memcpy(key_buf[prefix.len..][0..id.len], id);
    const key = key_buf[0 .. prefix.len + id.len];

    var batch = store.newBatch();
    defer batch.close();

    var buf: [64 * 1024]u8 = undefined;
    if (batch.getInto(key, &buf)) |val| {
        const job = codec.decodeJob(val);
        printJob(&job);

        // Also try to get payload.
        const pp = keys.prefix_job_payload;
        var pk_buf: [keys.max_key_len]u8 = undefined;
        @memcpy(pk_buf[0..pp.len], pp);
        @memcpy(pk_buf[pp.len..][0..id.len], id);
        const pk = pk_buf[0 .. pp.len + id.len];

        var pbuf: [64 * 1024]u8 = undefined;
        if (batch.getInto(pk, &pbuf)) |payload| {
            print("  payload:       {s}\n", .{payload});
        }
    } else {
        print("job not found: {s}\n", .{id});
        std.process.exit(1);
    }
}

fn cmdCount(store: *kv.Store, prefix: []const u8) void {
    var end_buf: [keys.max_key_len]u8 = undefined;
    const end = incrementPrefix(prefix, &end_buf) orelse {
        print("error: invalid prefix\n", .{});
        std.process.exit(1);
    };

    var batch = store.newBatch();
    defer batch.close();

    var iter = batch.newIter(prefix, end);
    defer iter.close();

    var count: usize = 0;
    var valid = iter.first();
    while (valid) {
        count += 1;
        valid = iter.next();
    }

    print("{d}\n", .{count});
}

// ============================================================================
// Decoding & Display
// ============================================================================

fn printDecodedValue(key: []const u8, val: []const u8) void {
    if (startsWith(key, keys.prefix_job_payload) or startsWith(key, keys.prefix_job_error)) {
        printRawValue(val);
    } else if (startsWith(key, keys.prefix_job)) {
        const job = codec.decodeJob(val);
        printJob(&job);
    } else if (startsWith(key, keys.prefix_queue_config)) {
        const q = codec.decodeQueue(val);
        printQueue(&q);
    } else if (startsWith(key, keys.prefix_worker)) {
        const w = codec.decodeWorker(val);
        printWorker(&w);
    } else if (startsWith(key, keys.prefix_cron)) {
        const c = codec.decodeCron(val);
        printCron(&c);
    } else if (startsWith(key, keys.prefix_batch)) {
        const b = codec.decodeBatch(val);
        printBatch(&b);
    } else if (startsWith(key, keys.prefix_budget)) {
        const bg = codec.decodeBudget(val);
        printBudget(&bg);
    } else {
        printRawValue(val);
    }
}

fn printRawValue(val: []const u8) void {
    if (isReadable(val)) {
        print("  value: {s}\n", .{val});
    } else {
        print("  value: ({d} bytes) ", .{val.len});
        printHex(val);
        print("\n", .{});
    }
}

fn printJob(job: *const types.Job) void {
    print("  id:            {s}\n", .{job.id});
    print("  queue:         {s}\n", .{job.queue});
    print("  state:         {s}\n", .{job.state.toString()});
    print("  priority:      {d}\n", .{job.priority});
    print("  attempt:       {d}/{d}\n", .{ job.attempt, job.max_retries });
    print("  backoff:       {s}\n", .{job.retry_backoff.toString()});
    if (job.retry_base_delay_ms > 0)
        print("  retry_delay:   {d}ms-{d}ms\n", .{ job.retry_base_delay_ms, job.retry_max_delay_ms });
    if (job.created_at_ns > 0)
        print("  created_at:    {d}\n", .{job.created_at_ns});
    if (job.started_at_ns > 0)
        print("  started_at:    {d}\n", .{job.started_at_ns});
    if (job.completed_at_ns > 0)
        print("  completed_at:  {d}\n", .{job.completed_at_ns});
    if (job.failed_at_ns > 0)
        print("  failed_at:     {d}\n", .{job.failed_at_ns});
    if (job.scheduled_at_ns > 0)
        print("  scheduled_at:  {d}\n", .{job.scheduled_at_ns});
    if (job.lease_expires_at_ns > 0)
        print("  lease_expires: {d}\n", .{job.lease_expires_at_ns});
    if (job.expire_at_ns > 0)
        print("  expire_at:     {d}\n", .{job.expire_at_ns});
    if (job.expire_after_ms > 0)
        print("  expire_after:  {d}ms\n", .{job.expire_after_ms});
    if (job.unique_key) |uk|
        print("  unique_key:    {s}\n", .{uk});
    if (job.batch_id) |bid|
        print("  batch_id:      {s}\n", .{bid});
    if (job.worker_id) |wid|
        print("  worker_id:     {s}\n", .{wid});
    if (job.hostname) |h|
        print("  hostname:      {s}\n", .{h});
    if (job.parent_id) |pid|
        print("  parent_id:     {s}\n", .{pid});
    if (job.chain_id) |cid|
        print("  chain_id:      {s}\n", .{cid});
    if (job.chain_step > 0)
        print("  chain_step:    {d}\n", .{job.chain_step});
    if (job.group) |g|
        print("  group:         {s}\n", .{g});
    if (job.hold_reason) |hr|
        print("  hold_reason:   {s}\n", .{hr});
    if (job.tags) |t|
        print("  tags:          {s}\n", .{t});
    if (job.progress) |p|
        print("  progress:      {s}\n", .{p});
    if (job.checkpoint) |cp|
        print("  checkpoint:    {s}\n", .{cp});
    if (job.result) |r|
        print("  result:        {s}\n", .{r});
    if (job.lease_token > 0)
        print("  lease_token:   {d}\n", .{job.lease_token});
}

fn printQueue(q: *const types.Queue) void {
    print("  name:            {s}\n", .{q.name});
    print("  paused:          {}\n", .{q.paused});
    print("  max_concurrency: {d}\n", .{q.max_concurrency});
    print("  rate_limit:      {d}\n", .{q.rate_limit});
    print("  rate_window_ms:  {d}\n", .{q.rate_window_ms});
    print("  fairness:        {}\n", .{q.fairness});
    if (q.created_at_ns > 0)
        print("  created_at:      {d}\n", .{q.created_at_ns});
}

fn printWorker(w: *const types.Worker) void {
    print("  id:              {s}\n", .{w.id});
    if (w.hostname) |h|
        print("  hostname:        {s}\n", .{h});
    if (w.queues) |q|
        print("  queues:          {s}\n", .{q});
    if (w.last_heartbeat_ns > 0)
        print("  last_heartbeat:  {d}\n", .{w.last_heartbeat_ns});
    if (w.started_at_ns > 0)
        print("  started_at:      {d}\n", .{w.started_at_ns});
}

fn printCron(c: *const types.Cron) void {
    print("  id:            {s}\n", .{c.id});
    print("  name:          {s}\n", .{c.name});
    print("  queue:         {s}\n", .{c.queue});
    print("  schedule:      {s}\n", .{c.schedule});
    print("  timezone:      {s}\n", .{c.timezone});
    print("  enabled:       {}\n", .{c.enabled});
    print("  max_retries:   {d}\n", .{c.max_retries});
    if (c.payload) |p|
        print("  payload:       {s}\n", .{p});
    if (c.unique_key) |uk|
        print("  unique_key:    {s}\n", .{uk});
    if (c.next_run_ns != 0)
        print("  next_run:      {d}\n", .{c.next_run_ns});
    if (c.last_run_ns != 0)
        print("  last_run:      {d}\n", .{c.last_run_ns});
    if (c.created_at_ns > 0)
        print("  created_at:    {d}\n", .{c.created_at_ns});
}

fn printBatch(b: *const types.Batch) void {
    print("  id:             {s}\n", .{b.id});
    print("  open:           {}\n", .{b.open});
    print("  total:          {d}\n", .{b.total});
    print("  pending:        {d}\n", .{b.pending});
    print("  succeeded:      {d}\n", .{b.succeeded});
    print("  failed:         {d}\n", .{b.failed});
    if (b.callback_queue) |cq|
        print("  callback_queue: {s}\n", .{cq});
    if (b.callback_payload) |cp|
        print("  callback_payload: {s}\n", .{cp});
    if (b.created_at_ns > 0)
        print("  created_at:     {d}\n", .{b.created_at_ns});
    if (b.completed_at_ns > 0)
        print("  completed_at:   {d}\n", .{b.completed_at_ns});
}

fn printBudget(bg: *const types.Budget) void {
    print("  scope:       {s}\n", .{bg.scope});
    print("  target:      {s}\n", .{bg.target});
    print("  daily_usd:   {d:.4}\n", .{bg.daily_usd});
    print("  per_job_usd: {d:.4}\n", .{bg.per_job_usd});
    print("  on_exceed:   {s}\n", .{bg.on_exceed});
    if (bg.created_at_ns > 0)
        print("  created_at:  {d}\n", .{bg.created_at_ns});
}

// ============================================================================
// Helpers
// ============================================================================

fn printKeyReadable(key: []const u8) void {
    for (key) |b| {
        if (b == 0x00) {
            print("\\0", .{});
        } else if (b >= 0x20 and b < 0x7f) {
            print("{c}", .{b});
        } else {
            print("\\x{x:0>2}", .{b});
        }
    }
}

fn printHex(data: []const u8) void {
    for (data) |b| {
        print("{x:0>2}", .{b});
    }
}

fn isReadable(data: []const u8) bool {
    for (data) |b| {
        if (b < 0x20 and b != '\n' and b != '\t') return false;
        if (b == 0x7f) return false;
    }
    return true;
}

fn startsWith(haystack: []const u8, prefix: []const u8) bool {
    return std.mem.startsWith(u8, haystack, prefix);
}

fn incrementPrefix(prefix: []const u8, buf: []u8) ?[]const u8 {
    if (prefix.len == 0) return null;
    @memcpy(buf[0..prefix.len], prefix);

    var i: usize = prefix.len;
    while (i > 0) {
        i -= 1;
        if (buf[i] < 0xFF) {
            buf[i] += 1;
            return buf[0 .. i + 1];
        }
    }
    return null;
}

fn printUsage() void {
    print(
        \\usage: corvo-inspect <data-dir> <command> [args]
        \\
        \\commands:
        \\  get <key>       lookup a single key (auto-decodes known prefixes)
        \\  scan <prefix>   iterate all keys with prefix (j|, x|, r|, a|, qc|, etc.)
        \\  job <id>        decode job header + payload for j|<id>
        \\  count <prefix>  count keys with prefix
        \\
        \\examples:
        \\  corvo-inspect /tmp/corvo-data get "j|my-job-id"
        \\  corvo-inspect /tmp/corvo-data scan "j|"
        \\  corvo-inspect /tmp/corvo-data scan "qc|"
        \\  corvo-inspect /tmp/corvo-data job my-job-id
        \\  corvo-inspect /tmp/corvo-data count "a|"
        \\
    , .{});
}
