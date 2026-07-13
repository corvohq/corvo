//! Binary codec for KV storage values.
//!
//! Replaces vtprotobuf — fixed-layout headers with varint-length strings.
//! All encode functions write into caller-provided buffers.
//! All decode functions return structs referencing the input slice (zero-copy).
//!
//! Format: fixed numeric fields first, then length-prefixed variable fields.
//! Lengths are 2-byte little-endian (max 65535 bytes per field).

const std = @import("std");
const assert = @import("assert.zig");
const types = @import("types.zig");

// ============================================================================
// Wire format version
// ============================================================================

const format_version: u8 = 3;

// ============================================================================
// Encoding helpers
// ============================================================================

fn writeU8(buf: []u8, pos: usize, v: u8) usize {
    buf[pos] = v;
    return pos + 1;
}

fn writeU16LE(buf: []u8, pos: usize, v: u16) usize {
    std.mem.writeInt(u16, buf[pos..][0..2], v, .little);
    return pos + 2;
}

fn writeU32LE(buf: []u8, pos: usize, v: u32) usize {
    std.mem.writeInt(u32, buf[pos..][0..4], v, .little);
    return pos + 4;
}

fn writeU64LE(buf: []u8, pos: usize, v: u64) usize {
    std.mem.writeInt(u64, buf[pos..][0..8], v, .little);
    return pos + 8;
}

fn writeF64LE(buf: []u8, pos: usize, v: f64) usize {
    return writeU64LE(buf, pos, @bitCast(v));
}

fn writeStr(buf: []u8, pos: usize, s: []const u8) usize {
    const p = writeU16LE(buf, pos, @intCast(s.len));
    if (s.len > 0) @memcpy(buf[p..][0..s.len], s);
    return p + s.len;
}

fn writeOptStr(buf: []u8, pos: usize, s: ?[]const u8) usize {
    return writeStr(buf, pos, s orelse "");
}

// ============================================================================
// Decoding helpers
// ============================================================================

fn readU8(data: []const u8, pos: usize) struct { val: u8, next: usize } {
    return .{ .val = data[pos], .next = pos + 1 };
}

fn readU16LE(data: []const u8, pos: usize) struct { val: u16, next: usize } {
    return .{ .val = std.mem.readInt(u16, data[pos..][0..2], .little), .next = pos + 2 };
}

fn readU32LE(data: []const u8, pos: usize) struct { val: u32, next: usize } {
    return .{ .val = std.mem.readInt(u32, data[pos..][0..4], .little), .next = pos + 4 };
}

fn readU64LE(data: []const u8, pos: usize) struct { val: u64, next: usize } {
    return .{ .val = std.mem.readInt(u64, data[pos..][0..8], .little), .next = pos + 8 };
}

fn readF64LE(data: []const u8, pos: usize) struct { val: f64, next: usize } {
    const r = readU64LE(data, pos);
    return .{ .val = @bitCast(r.val), .next = r.next };
}

fn readStr(data: []const u8, pos: usize) struct { val: []const u8, next: usize } {
    const len_r = readU16LE(data, pos);
    const len: usize = len_r.val;
    const start = len_r.next;
    return .{ .val = data[start..][0..len], .next = start + len };
}

fn readOptStr(data: []const u8, pos: usize) struct { val: ?[]const u8, next: usize } {
    const r = readStr(data, pos);
    return .{ .val = if (r.val.len == 0) null else r.val, .next = r.next };
}

// ============================================================================
// Job Header Codec (v2 — agent fields removed)
// ============================================================================
//
// Fixed fields:
//   [0]     version (u8)
//   [1]     state (u8)
//   [2]     priority (u8)
//   [3..4]  attempt (u16 LE)
//   [5..6]  max_retries (u16 LE)
//   [7]     retry_backoff (u8)
//   [8..11] retry_base_delay_ms (u32 LE)
//   [12..15] retry_max_delay_ms (u32 LE)
//   [16..19] unique_period_s (u32 LE)
//   [20..23] expire_after_ms (u32 LE)
//   [24..25] chain_step (u16 LE)
//   [26..33] created_at_ns (u64 LE)
//   [34..41] started_at_ns (u64 LE)
//   [42..49] completed_at_ns (u64 LE)
//   [50..57] failed_at_ns (u64 LE)
//   [58..65] scheduled_at_ns (u64 LE)
//   [66..73] lease_expires_at_ns (u64 LE)
//   [74..81] expire_at_ns (u64 LE)
//   [82]    flags (u8): reserved
//
// Variable fields (length-prefixed, 2-byte LE length each):
//   id, queue, unique_key, batch_id, worker_id, hostname,
//   parent_id, chain_id, chain_config, group, hold_reason,
//   tags, progress, checkpoint, result

const job_fixed_size: usize = 91;

/// New jobs are capped below this value by the enqueue handler, leaving room
/// for worker, heartbeat, and completion metadata added over the job's life.
pub const max_enqueue_job_encoded_size: usize = 4096;
pub const max_job_encoded_size: usize = 8192;

/// Exact bytes encodeJob will write. Boundary handlers use this before the
/// fixed-buffer encoder so oversized combinations of individually-valid fields
/// become client errors instead of slice-bounds panics.
pub fn jobEncodedSize(job: *const types.Job) usize {
    return job_fixed_size + 15 * 2 +
        job.id.len + job.queue.len +
        (job.unique_key orelse "").len +
        (job.batch_id orelse "").len +
        (job.worker_id orelse "").len +
        (job.hostname orelse "").len +
        (job.parent_id orelse "").len +
        (job.chain_id orelse "").len +
        (job.chain_config orelse "").len +
        (job.group orelse "").len +
        (job.hold_reason orelse "").len +
        (job.tags orelse "").len +
        (job.progress orelse "").len +
        (job.checkpoint orelse "").len +
        (job.result orelse "").len;
}

/// Encode a Job header into buf. Returns the encoded slice.
/// Payload is NOT included — stored separately at jp|{id}.
pub fn encodeJob(buf: []u8, job: *const types.Job) []const u8 {
    assert.check(buf.len >= job_fixed_size, "encodeJob: buffer too small ({d})", .{buf.len});
    assert.check(jobEncodedSize(job) <= buf.len, "encodeJob: encoded job exceeds buffer ({d} > {d})", .{ jobEncodedSize(job), buf.len });

    var pos: usize = 0;

    // Fixed fields
    pos = writeU8(buf, pos, format_version);
    pos = writeU8(buf, pos, @intFromEnum(job.state));
    pos = writeU8(buf, pos, job.priority);
    pos = writeU16LE(buf, pos, job.attempt);
    pos = writeU16LE(buf, pos, job.max_retries);
    pos = writeU8(buf, pos, @intFromEnum(job.retry_backoff));
    pos = writeU32LE(buf, pos, job.retry_base_delay_ms);
    pos = writeU32LE(buf, pos, job.retry_max_delay_ms);
    pos = writeU32LE(buf, pos, job.unique_period_s);
    pos = writeU32LE(buf, pos, job.expire_after_ms);
    pos = writeU16LE(buf, pos, job.chain_step);

    // Timestamps
    pos = writeU64LE(buf, pos, job.created_at_ns);
    pos = writeU64LE(buf, pos, job.started_at_ns);
    pos = writeU64LE(buf, pos, job.completed_at_ns);
    pos = writeU64LE(buf, pos, job.failed_at_ns);
    pos = writeU64LE(buf, pos, job.scheduled_at_ns);
    pos = writeU64LE(buf, pos, job.lease_expires_at_ns);
    pos = writeU64LE(buf, pos, job.expire_at_ns);

    // Flags (reserved)
    pos = writeU8(buf, pos, 0);

    // Lease token
    pos = writeU64LE(buf, pos, job.lease_token);

    // Variable-length fields
    pos = writeStr(buf, pos, job.id);
    pos = writeStr(buf, pos, job.queue);
    pos = writeOptStr(buf, pos, job.unique_key);
    pos = writeOptStr(buf, pos, job.batch_id);
    pos = writeOptStr(buf, pos, job.worker_id);
    pos = writeOptStr(buf, pos, job.hostname);
    pos = writeOptStr(buf, pos, job.parent_id);
    pos = writeOptStr(buf, pos, job.chain_id);
    pos = writeOptStr(buf, pos, job.chain_config);
    pos = writeOptStr(buf, pos, job.group);
    pos = writeOptStr(buf, pos, job.hold_reason);
    pos = writeOptStr(buf, pos, job.tags);
    pos = writeOptStr(buf, pos, job.progress);
    pos = writeOptStr(buf, pos, job.checkpoint);
    pos = writeOptStr(buf, pos, job.result);

    return buf[0..pos];
}

/// Decode a Job header from KV value bytes. Returned strings reference
/// the input data slice — caller must ensure data outlives the Job.
pub fn decodeJob(data: []const u8) types.Job {
    assert.check(data.len >= job_fixed_size, "decodeJob: data too short ({d})", .{data.len});

    var pos: usize = 0;
    var job: types.Job = .{};

    // Fixed fields
    const ver = readU8(data, pos);
    pos = ver.next;
    assert.check(ver.val == format_version, "decodeJob: unknown version {d}", .{ver.val});

    const state = readU8(data, pos);
    pos = state.next;
    job.state = @enumFromInt(state.val);

    const pri = readU8(data, pos);
    pos = pri.next;
    job.priority = pri.val;

    const attempt = readU16LE(data, pos);
    pos = attempt.next;
    job.attempt = attempt.val;

    const max_retries = readU16LE(data, pos);
    pos = max_retries.next;
    job.max_retries = max_retries.val;

    const backoff = readU8(data, pos);
    pos = backoff.next;
    job.retry_backoff = @enumFromInt(backoff.val);

    const base_delay = readU32LE(data, pos);
    pos = base_delay.next;
    job.retry_base_delay_ms = base_delay.val;

    const max_delay = readU32LE(data, pos);
    pos = max_delay.next;
    job.retry_max_delay_ms = max_delay.val;

    const unique_period = readU32LE(data, pos);
    pos = unique_period.next;
    job.unique_period_s = unique_period.val;

    const expire_after = readU32LE(data, pos);
    pos = expire_after.next;
    job.expire_after_ms = expire_after.val;

    const chain_step = readU16LE(data, pos);
    pos = chain_step.next;
    job.chain_step = chain_step.val;

    // Timestamps
    const created = readU64LE(data, pos);
    pos = created.next;
    job.created_at_ns = created.val;

    const started = readU64LE(data, pos);
    pos = started.next;
    job.started_at_ns = started.val;

    const completed = readU64LE(data, pos);
    pos = completed.next;
    job.completed_at_ns = completed.val;

    const failed = readU64LE(data, pos);
    pos = failed.next;
    job.failed_at_ns = failed.val;

    const scheduled = readU64LE(data, pos);
    pos = scheduled.next;
    job.scheduled_at_ns = scheduled.val;

    const lease_expires = readU64LE(data, pos);
    pos = lease_expires.next;
    job.lease_expires_at_ns = lease_expires.val;

    const expire_at = readU64LE(data, pos);
    pos = expire_at.next;
    job.expire_at_ns = expire_at.val;

    // Flags
    pos = readU8(data, pos).next; // flags (reserved)

    // Lease token
    const lease_token = readU64LE(data, pos);
    pos = lease_token.next;
    job.lease_token = lease_token.val;

    // Variable fields
    const id = readStr(data, pos);
    pos = id.next;
    job.id = id.val;

    const queue = readStr(data, pos);
    pos = queue.next;
    job.queue = queue.val;

    const unique_key = readOptStr(data, pos);
    pos = unique_key.next;
    job.unique_key = unique_key.val;

    const batch_id = readOptStr(data, pos);
    pos = batch_id.next;
    job.batch_id = batch_id.val;

    const worker_id = readOptStr(data, pos);
    pos = worker_id.next;
    job.worker_id = worker_id.val;

    const hostname = readOptStr(data, pos);
    pos = hostname.next;
    job.hostname = hostname.val;

    const parent_id = readOptStr(data, pos);
    pos = parent_id.next;
    job.parent_id = parent_id.val;

    const chain_id = readOptStr(data, pos);
    pos = chain_id.next;
    job.chain_id = chain_id.val;

    const chain_config = readOptStr(data, pos);
    pos = chain_config.next;
    job.chain_config = chain_config.val;

    const group = readOptStr(data, pos);
    pos = group.next;
    job.group = group.val;

    const hold_reason = readOptStr(data, pos);
    pos = hold_reason.next;
    job.hold_reason = hold_reason.val;

    const tag_data = readOptStr(data, pos);
    pos = tag_data.next;
    job.tags = tag_data.val;

    const progress_data = readOptStr(data, pos);
    pos = progress_data.next;
    job.progress = progress_data.val;

    const checkpoint_data = readOptStr(data, pos);
    pos = checkpoint_data.next;
    job.checkpoint = checkpoint_data.val;

    const result_data = readOptStr(data, pos);
    pos = result_data.next;
    job.result = result_data.val;

    return job;
}

// ============================================================================
// Queue Config Codec
// ============================================================================
//
// Fixed fields (54 bytes):
//   [0]     version (u8)
//   [1]     flags (u8): bit0=paused, bit1=fairness
//   [2..5]  max_concurrency (u32 LE)
//   [6..9]  rate_limit (u32 LE)
//   [10..13] rate_window_ms (u32 LE)
//   [14..21] created_at_ns (u64 LE)
//   [22..25] pending_count (u32 LE)
//   [26..29] active_count (u32 LE)
//   [30..33] retrying_count (u32 LE)
//   [34..37] completed_count (u32 LE)
//   [38..41] dead_count (u32 LE)
//   [42..45] cancelled_count (u32 LE)
//   [46..49] scheduled_count (u32 LE)
//   [50..53] held_count (u32 LE)
//
// Variable fields:
//   name

const queue_fixed_size: usize = 54;
pub const max_queue_encoded_size: usize = 512;

pub fn encodeQueue(buf: []u8, q: *const types.Queue) []const u8 {
    assert.check(buf.len >= queue_fixed_size, "encodeQueue: buffer too small", .{});

    var pos: usize = 0;
    pos = writeU8(buf, pos, format_version);

    var flags: u8 = 0;
    if (q.paused) flags |= 1;
    if (q.fairness) flags |= 2;
    pos = writeU8(buf, pos, flags);

    pos = writeU32LE(buf, pos, q.max_concurrency);
    pos = writeU32LE(buf, pos, q.rate_limit);
    pos = writeU32LE(buf, pos, q.rate_window_ms);
    pos = writeU64LE(buf, pos, q.created_at_ns);

    // Per-state counters
    pos = writeU32LE(buf, pos, q.pending_count);
    pos = writeU32LE(buf, pos, q.active_count);
    pos = writeU32LE(buf, pos, q.retrying_count);
    pos = writeU32LE(buf, pos, q.completed_count);
    pos = writeU32LE(buf, pos, q.dead_count);
    pos = writeU32LE(buf, pos, q.cancelled_count);
    pos = writeU32LE(buf, pos, q.scheduled_count);
    pos = writeU32LE(buf, pos, q.held_count);

    pos = writeStr(buf, pos, q.name);

    return buf[0..pos];
}

pub fn decodeQueue(data: []const u8) types.Queue {
    assert.check(data.len >= queue_fixed_size, "decodeQueue: data too short ({d})", .{data.len});

    var pos: usize = 0;
    var q: types.Queue = .{};

    const ver = readU8(data, pos);
    pos = ver.next;
    assert.check(ver.val == format_version, "decodeQueue: unknown version {d}", .{ver.val});

    const flags = readU8(data, pos);
    pos = flags.next;
    q.paused = (flags.val & 1) != 0;
    q.fairness = (flags.val & 2) != 0;

    const max_conc = readU32LE(data, pos);
    pos = max_conc.next;
    q.max_concurrency = max_conc.val;

    const rate_limit = readU32LE(data, pos);
    pos = rate_limit.next;
    q.rate_limit = rate_limit.val;

    const rate_window = readU32LE(data, pos);
    pos = rate_window.next;
    q.rate_window_ms = rate_window.val;

    const created = readU64LE(data, pos);
    pos = created.next;
    q.created_at_ns = created.val;

    // Per-state counters
    const pc = readU32LE(data, pos);
    pos = pc.next;
    q.pending_count = pc.val;
    const ac = readU32LE(data, pos);
    pos = ac.next;
    q.active_count = ac.val;
    const rc = readU32LE(data, pos);
    pos = rc.next;
    q.retrying_count = rc.val;
    const cc = readU32LE(data, pos);
    pos = cc.next;
    q.completed_count = cc.val;
    const dc = readU32LE(data, pos);
    pos = dc.next;
    q.dead_count = dc.val;
    const xc = readU32LE(data, pos);
    pos = xc.next;
    q.cancelled_count = xc.val;
    const sc = readU32LE(data, pos);
    pos = sc.next;
    q.scheduled_count = sc.val;
    const hc = readU32LE(data, pos);
    pos = hc.next;
    q.held_count = hc.val;

    const name = readStr(data, pos);
    pos = name.next;
    q.name = name.val;

    return q;
}

// ============================================================================
// Worker State Codec
// ============================================================================
//
// Fixed fields (17 bytes):
//   [0]     version (u8)
//   [1..8]  last_heartbeat_ns (u64 LE)
//   [9..16] started_at_ns (u64 LE)
//
// Variable fields:
//   id, hostname, queues

const worker_fixed_size: usize = 17;
pub const max_worker_encoded_size: usize = 1024;

pub fn workerEncodedSize(w: *const types.Worker) usize {
    return worker_fixed_size + 3 * 2 +
        w.id.len +
        (w.hostname orelse "").len +
        (w.queues orelse "").len;
}

pub fn encodeWorker(buf: []u8, w: *const types.Worker) []const u8 {
    assert.check(buf.len >= worker_fixed_size, "encodeWorker: buffer too small", .{});
    assert.check(workerEncodedSize(w) <= buf.len, "encodeWorker: encoded worker exceeds buffer ({d} > {d})", .{ workerEncodedSize(w), buf.len });

    var pos: usize = 0;
    pos = writeU8(buf, pos, format_version);
    pos = writeU64LE(buf, pos, w.last_heartbeat_ns);
    pos = writeU64LE(buf, pos, w.started_at_ns);

    pos = writeStr(buf, pos, w.id);
    pos = writeOptStr(buf, pos, w.hostname);
    pos = writeOptStr(buf, pos, w.queues);

    return buf[0..pos];
}

pub fn decodeWorker(data: []const u8) types.Worker {
    assert.check(data.len >= worker_fixed_size, "decodeWorker: data too short ({d})", .{data.len});

    var pos: usize = 0;
    var w: types.Worker = .{};

    const ver = readU8(data, pos);
    pos = ver.next;
    assert.check(ver.val == format_version, "decodeWorker: unknown version {d}", .{ver.val});

    const heartbeat = readU64LE(data, pos);
    pos = heartbeat.next;
    w.last_heartbeat_ns = heartbeat.val;

    const started = readU64LE(data, pos);
    pos = started.next;
    w.started_at_ns = started.val;

    const id = readStr(data, pos);
    pos = id.next;
    w.id = id.val;

    const hostname = readOptStr(data, pos);
    pos = hostname.next;
    w.hostname = hostname.val;

    const queues = readOptStr(data, pos);
    pos = queues.next;
    w.queues = queues.val;

    return w;
}

// ============================================================================
// Cron Codec
// ============================================================================
//
// Fixed fields:
//   [0]     version (u8)
//   [1..2]  max_retries (u16 LE)
//   [3]     flags (u8): bit0=enabled
//   [4..11] next_run_ns (i64 LE)
//   [12..19] last_run_ns (i64 LE)
//   [20..27] created_at_ns (u64 LE)
//
// Variable fields:
//   id, name, queue, schedule, timezone, payload, unique_key

const cron_fixed_size: usize = 28;
pub const max_cron_encoded_size: usize = 2048;

pub fn cronEncodedSize(c: *const types.Cron) usize {
    return cron_fixed_size + 7 * 2 +
        c.id.len + c.name.len + c.queue.len + c.schedule.len + c.timezone.len +
        (c.payload orelse "").len +
        (c.unique_key orelse "").len;
}

pub fn encodeCron(buf: []u8, c: *const types.Cron) []const u8 {
    assert.check(buf.len >= cron_fixed_size, "encodeCron: buffer too small", .{});
    assert.check(cronEncodedSize(c) <= buf.len, "encodeCron: encoded cron exceeds buffer ({d} > {d})", .{ cronEncodedSize(c), buf.len });

    var pos: usize = 0;
    pos = writeU8(buf, pos, format_version);
    pos = writeU16LE(buf, pos, c.max_retries);

    var flags: u8 = 0;
    if (c.enabled) flags |= 1;
    pos = writeU8(buf, pos, flags);

    pos = writeU64LE(buf, pos, @bitCast(c.next_run_ns));
    pos = writeU64LE(buf, pos, @bitCast(c.last_run_ns));
    pos = writeU64LE(buf, pos, c.created_at_ns);

    pos = writeStr(buf, pos, c.id);
    pos = writeStr(buf, pos, c.name);
    pos = writeStr(buf, pos, c.queue);
    pos = writeStr(buf, pos, c.schedule);
    pos = writeStr(buf, pos, c.timezone);
    pos = writeOptStr(buf, pos, c.payload);
    pos = writeOptStr(buf, pos, c.unique_key);

    return buf[0..pos];
}

pub fn decodeCron(data: []const u8) types.Cron {
    assert.check(data.len >= cron_fixed_size, "decodeCron: data too short ({d})", .{data.len});

    var pos: usize = 0;
    var c: types.Cron = .{};

    const ver = readU8(data, pos);
    pos = ver.next;
    assert.check(ver.val == format_version, "decodeCron: unknown version {d}", .{ver.val});

    const max_retries = readU16LE(data, pos);
    pos = max_retries.next;
    c.max_retries = max_retries.val;

    const flags = readU8(data, pos);
    pos = flags.next;
    c.enabled = (flags.val & 1) != 0;

    const next_run = readU64LE(data, pos);
    pos = next_run.next;
    c.next_run_ns = @bitCast(next_run.val);

    const last_run = readU64LE(data, pos);
    pos = last_run.next;
    c.last_run_ns = @bitCast(last_run.val);

    const created = readU64LE(data, pos);
    pos = created.next;
    c.created_at_ns = created.val;

    const id = readStr(data, pos);
    pos = id.next;
    c.id = id.val;

    const name = readStr(data, pos);
    pos = name.next;
    c.name = name.val;

    const queue = readStr(data, pos);
    pos = queue.next;
    c.queue = queue.val;

    const schedule = readStr(data, pos);
    pos = schedule.next;
    c.schedule = schedule.val;

    const timezone = readStr(data, pos);
    pos = timezone.next;
    c.timezone = timezone.val;

    const payload = readOptStr(data, pos);
    pos = payload.next;
    c.payload = payload.val;

    const unique_key = readOptStr(data, pos);
    pos = unique_key.next;
    c.unique_key = unique_key.val;

    return c;
}

// ============================================================================
// Batch Codec
// ============================================================================
//
// Fixed fields:
//   [0]     version (u8)
//   [1]     flags (u8): bit0=open
//   [2..5]  total (u32 LE)
//   [6..9]  succeeded (u32 LE)
//   [10..13] pending (u32 LE)
//   [14..17] failed (u32 LE)
//   [18..25] created_at_ns (u64 LE)
//   [26..33] completed_at_ns (u64 LE)
//
// Variable fields:
//   id, callback_queue, callback_payload

const batch_fixed_size: usize = 34;
pub const max_batch_encoded_size: usize = 2048;

pub fn batchEncodedSize(b: *const types.Batch) usize {
    return batch_fixed_size + 3 * 2 +
        b.id.len +
        (b.callback_queue orelse "").len +
        (b.callback_payload orelse "").len;
}

pub fn encodeBatch(buf: []u8, b: *const types.Batch) []const u8 {
    assert.check(buf.len >= batch_fixed_size, "encodeBatch: buffer too small", .{});
    assert.check(batchEncodedSize(b) <= buf.len, "encodeBatch: encoded batch exceeds buffer ({d} > {d})", .{ batchEncodedSize(b), buf.len });

    var pos: usize = 0;
    pos = writeU8(buf, pos, format_version);

    var flags: u8 = 0;
    if (b.open) flags |= 1;
    pos = writeU8(buf, pos, flags);

    pos = writeU32LE(buf, pos, b.total);
    pos = writeU32LE(buf, pos, b.succeeded);
    pos = writeU32LE(buf, pos, b.pending);
    pos = writeU32LE(buf, pos, b.failed);
    pos = writeU64LE(buf, pos, b.created_at_ns);
    pos = writeU64LE(buf, pos, b.completed_at_ns);

    pos = writeStr(buf, pos, b.id);
    pos = writeOptStr(buf, pos, b.callback_queue);
    pos = writeOptStr(buf, pos, b.callback_payload);

    return buf[0..pos];
}

pub fn decodeBatch(data: []const u8) types.Batch {
    assert.check(data.len >= batch_fixed_size, "decodeBatch: data too short ({d})", .{data.len});

    var pos: usize = 0;
    var b: types.Batch = .{};

    const ver = readU8(data, pos);
    pos = ver.next;
    assert.check(ver.val == format_version, "decodeBatch: unknown version {d}", .{ver.val});

    const flags = readU8(data, pos);
    pos = flags.next;
    b.open = (flags.val & 1) != 0;

    const total = readU32LE(data, pos);
    pos = total.next;
    b.total = total.val;

    const succeeded = readU32LE(data, pos);
    pos = succeeded.next;
    b.succeeded = succeeded.val;

    const pending = readU32LE(data, pos);
    pos = pending.next;
    b.pending = pending.val;

    const failed = readU32LE(data, pos);
    pos = failed.next;
    b.failed = failed.val;

    const created = readU64LE(data, pos);
    pos = created.next;
    b.created_at_ns = created.val;

    const completed = readU64LE(data, pos);
    pos = completed.next;
    b.completed_at_ns = completed.val;

    const id = readStr(data, pos);
    pos = id.next;
    b.id = id.val;

    const callback_queue = readOptStr(data, pos);
    pos = callback_queue.next;
    b.callback_queue = callback_queue.val;

    const callback_payload = readOptStr(data, pos);
    pos = callback_payload.next;
    b.callback_payload = callback_payload.val;

    return b;
}

// ============================================================================
// Budget Codec
// ============================================================================
//
// Fixed layout: [1B version][8B dailyUSD bits][8B perJobUSD bits][8B createdAtNs]
// Variable:     [2B scope][scope][2B target][target][2B onExceed][onExceed]

const budget_fixed_size: usize = 1 + 8 + 8 + 8; // 25 bytes

pub const max_budget_encoded_size: usize = 1024;

pub fn budgetEncodedSize(bg: *const types.Budget) usize {
    return budget_fixed_size + 3 * 2 + bg.scope.len + bg.target.len + bg.on_exceed.len;
}

pub fn encodeBudget(buf: []u8, bg: *const types.Budget) []const u8 {
    assert.check(buf.len >= budget_fixed_size, "encodeBudget: buffer too small", .{});
    assert.check(budgetEncodedSize(bg) <= buf.len, "encodeBudget: encoded budget exceeds buffer ({d} > {d})", .{ budgetEncodedSize(bg), buf.len });

    var pos: usize = 0;
    pos = writeU8(buf, pos, format_version);
    pos = writeF64LE(buf, pos, bg.daily_usd);
    pos = writeF64LE(buf, pos, bg.per_job_usd);
    pos = writeU64LE(buf, pos, bg.created_at_ns);
    pos = writeStr(buf, pos, bg.scope);
    pos = writeStr(buf, pos, bg.target);
    pos = writeStr(buf, pos, bg.on_exceed);

    return buf[0..pos];
}

pub fn decodeBudget(data: []const u8) types.Budget {
    assert.check(data.len >= budget_fixed_size, "decodeBudget: data too short ({d})", .{data.len});

    var pos: usize = 0;
    var bg: types.Budget = .{};

    const ver = readU8(data, pos);
    pos = ver.next;
    assert.check(ver.val == format_version, "decodeBudget: unknown version {d}", .{ver.val});

    const daily = readF64LE(data, pos);
    pos = daily.next;
    bg.daily_usd = daily.val;

    const per_job = readF64LE(data, pos);
    pos = per_job.next;
    bg.per_job_usd = per_job.val;

    const created = readU64LE(data, pos);
    pos = created.next;
    bg.created_at_ns = created.val;

    const scope = readStr(data, pos);
    pos = scope.next;
    bg.scope = scope.val;

    const target = readStr(data, pos);
    pos = target.next;
    bg.target = target.val;

    const on_exceed = readStr(data, pos);
    pos = on_exceed.next;
    bg.on_exceed = on_exceed.val;

    return bg;
}

// ============================================================================
// Tests
// ============================================================================

test "job encode/decode roundtrip" {
    const job = types.Job{
        .id = "job-abc-123",
        .queue = "default",
        .state = .active,
        .priority = 75,
        .attempt = 2,
        .max_retries = 5,
        .retry_backoff = .exponential,
        .retry_base_delay_ms = 1000,
        .retry_max_delay_ms = 60000,
        .created_at_ns = 1710000000000000000,
        .started_at_ns = 1710000001000000000,
        .unique_key = "ukey",
        .batch_id = "batch-1",
        .tags = "[\"urgent\"]",
        .group = "tenant-a",
    };

    var buf: [max_job_encoded_size]u8 = undefined;
    const encoded = encodeJob(&buf, &job);
    const decoded = decodeJob(encoded);

    const testing = std.testing;
    try testing.expectEqualStrings("job-abc-123", decoded.id);
    try testing.expectEqualStrings("default", decoded.queue);
    try testing.expectEqual(types.JobState.active, decoded.state);
    try testing.expectEqual(@as(u8, 75), decoded.priority);
    try testing.expectEqual(@as(u16, 2), decoded.attempt);
    try testing.expectEqual(@as(u16, 5), decoded.max_retries);
    try testing.expectEqual(types.Backoff.exponential, decoded.retry_backoff);
    try testing.expectEqual(@as(u32, 1000), decoded.retry_base_delay_ms);
    try testing.expectEqual(@as(u32, 60000), decoded.retry_max_delay_ms);
    try testing.expectEqual(@as(u64, 1710000000000000000), decoded.created_at_ns);
    try testing.expectEqual(@as(u64, 1710000001000000000), decoded.started_at_ns);
    try testing.expectEqualStrings("ukey", decoded.unique_key.?);
    try testing.expectEqualStrings("batch-1", decoded.batch_id.?);
    try testing.expectEqualStrings("[\"urgent\"]", decoded.tags.?);
    try testing.expectEqualStrings("tenant-a", decoded.group.?);
}

test "job encode/decode minimal" {
    const job = types.Job{
        .id = "j1",
        .queue = "q",
        .state = .pending,
    };

    var buf: [max_job_encoded_size]u8 = undefined;
    const encoded = encodeJob(&buf, &job);
    const decoded = decodeJob(encoded);

    const testing = std.testing;
    try testing.expectEqualStrings("j1", decoded.id);
    try testing.expectEqualStrings("q", decoded.queue);
    try testing.expectEqual(types.JobState.pending, decoded.state);
    try testing.expect(decoded.unique_key == null);
    try testing.expect(decoded.batch_id == null);
    try testing.expect(decoded.tags == null);
}

test "queue encode/decode roundtrip" {
    const q = types.Queue{
        .name = "emails",
        .paused = true,
        .max_concurrency = 10,
        .rate_limit = 100,
        .rate_window_ms = 5000,
        .fairness = true,
        .created_at_ns = 1710000000000000000,
        .pending_count = 42,
        .active_count = 7,
        .retrying_count = 3,
        .completed_count = 1000,
        .dead_count = 5,
        .cancelled_count = 8,
        .scheduled_count = 12,
        .held_count = 2,
    };

    var buf: [max_queue_encoded_size]u8 = undefined;
    const encoded = encodeQueue(&buf, &q);
    const decoded = decodeQueue(encoded);

    const testing = std.testing;
    try testing.expectEqualStrings("emails", decoded.name);
    try testing.expect(decoded.paused);
    try testing.expect(decoded.fairness);
    try testing.expectEqual(@as(u32, 10), decoded.max_concurrency);
    try testing.expectEqual(@as(u32, 100), decoded.rate_limit);
    try testing.expectEqual(@as(u32, 5000), decoded.rate_window_ms);
    try testing.expectEqual(@as(u64, 1710000000000000000), decoded.created_at_ns);
    try testing.expectEqual(@as(u32, 42), decoded.pending_count);
    try testing.expectEqual(@as(u32, 7), decoded.active_count);
    try testing.expectEqual(@as(u32, 3), decoded.retrying_count);
    try testing.expectEqual(@as(u32, 1000), decoded.completed_count);
    try testing.expectEqual(@as(u32, 5), decoded.dead_count);
    try testing.expectEqual(@as(u32, 8), decoded.cancelled_count);
    try testing.expectEqual(@as(u32, 12), decoded.scheduled_count);
    try testing.expectEqual(@as(u32, 2), decoded.held_count);
}

test "worker encode/decode roundtrip" {
    const w = types.Worker{
        .id = "worker-1",
        .hostname = "host-a",
        .queues = "[\"default\",\"emails\"]",
        .last_heartbeat_ns = 1710000000000000000,
        .started_at_ns = 1709999000000000000,
    };

    var buf: [max_worker_encoded_size]u8 = undefined;
    const encoded = encodeWorker(&buf, &w);
    const decoded = decodeWorker(encoded);

    const testing = std.testing;
    try testing.expectEqualStrings("worker-1", decoded.id);
    try testing.expectEqualStrings("host-a", decoded.hostname.?);
    try testing.expectEqualStrings("[\"default\",\"emails\"]", decoded.queues.?);
    try testing.expectEqual(@as(u64, 1710000000000000000), decoded.last_heartbeat_ns);
}

test "cron encode/decode roundtrip" {
    const c = types.Cron{
        .id = "cron-1",
        .name = "daily-cleanup",
        .queue = "maintenance",
        .schedule = "0 0 * * *",
        .timezone = "UTC",
        .payload = "{\"action\":\"cleanup\"}",
        .max_retries = 3,
        .enabled = true,
        .next_run_ns = 1710086400000000000,
        .last_run_ns = 1710000000000000000,
        .created_at_ns = 1709900000000000000,
    };

    var buf: [max_cron_encoded_size]u8 = undefined;
    const encoded = encodeCron(&buf, &c);
    const decoded = decodeCron(encoded);

    const testing = std.testing;
    try testing.expectEqualStrings("cron-1", decoded.id);
    try testing.expectEqualStrings("daily-cleanup", decoded.name);
    try testing.expectEqualStrings("maintenance", decoded.queue);
    try testing.expectEqualStrings("0 0 * * *", decoded.schedule);
    try testing.expectEqualStrings("UTC", decoded.timezone);
    try testing.expectEqualStrings("{\"action\":\"cleanup\"}", decoded.payload.?);
    try testing.expectEqual(@as(u16, 3), decoded.max_retries);
    try testing.expect(decoded.enabled);
}

test "batch encode/decode roundtrip" {
    const b = types.Batch{
        .id = "batch-1",
        .open = false,
        .total = 100,
        .pending = 0,
        .succeeded = 95,
        .failed = 5,
        .callback_queue = "results",
        .callback_payload = "{\"notify\":true}",
        .created_at_ns = 1710000000000000000,
        .completed_at_ns = 1710000060000000000,
    };

    var buf: [max_batch_encoded_size]u8 = undefined;
    const encoded = encodeBatch(&buf, &b);
    const decoded = decodeBatch(encoded);

    const testing = std.testing;
    try testing.expectEqualStrings("batch-1", decoded.id);
    try testing.expect(!decoded.open);
    try testing.expectEqual(@as(u32, 100), decoded.total);
    try testing.expectEqual(@as(u32, 0), decoded.pending);
    try testing.expectEqual(@as(u32, 95), decoded.succeeded);
    try testing.expectEqual(@as(u32, 5), decoded.failed);
    try testing.expectEqualStrings("results", decoded.callback_queue.?);
    try testing.expectEqualStrings("{\"notify\":true}", decoded.callback_payload.?);
}
