//! Key encoding for KV storage.
//!
//! Ported from Go internal/kv/keys.go. Every key has a prefix ending with '|'
//! and sub-fields separated by \x00. Numeric fields are big-endian for
//! lexicographic sort order.
//!
//! All functions write into caller-provided buffers and return slices.
//! No allocations — suitable for hot-path use inside the apply loop.

const std = @import("std");
const assert = @import("assert.zig");

// ============================================================================
// Key Prefixes
// ============================================================================

pub const prefix_job = "j|"; // j|{job_id}
pub const prefix_job_payload = "jp|"; // jp|{job_id}
pub const prefix_job_error = "je|"; // je|{job_id}\x00{attempt:4BE}
pub const prefix_pending = "p|"; // p|{queue}\x00{inv_pri:1}{created_ns:8BE}{job_id}
pub const prefix_active = "a|"; // a|{queue}\x00{job_id}
pub const prefix_scheduled = "s|"; // s|{queue}\x00{scheduled_ns:8BE}{job_id}
pub const prefix_retrying = "r|"; // r|{queue}\x00{retry_ns:8BE}{job_id}
pub const prefix_queue_config = "qc|"; // qc|{queue}
pub const prefix_queue_name = "qn|"; // qn|{queue}
pub const prefix_unique = "u|"; // u|{queue}\x00{unique_key}
pub const prefix_rate_limit = "l|"; // l|{queue}\x00{fetched_ns:8BE}{random:8BE}
pub const prefix_batch = "b|"; // b|{batch_id}
pub const prefix_worker = "w|"; // w|{worker_id}
pub const prefix_cron = "sc|"; // sc|{cron_id}
pub const prefix_cron_name = "cn|"; // cn|{name}
pub const prefix_event_log = "ev|"; // ev|{seq:8BE}
pub const key_event_cursor = "evc|"; // evc| (singleton)
pub const prefix_budget = "bg|"; // bg|{scope}\x00{target}
pub const prefix_provider = "pv|"; // pv|{name}
pub const prefix_queue_prov = "qp|"; // qp|{queue}
pub const prefix_expire = "x|"; // x|{expireAtNs:8BE}{jobID}
pub const prefix_dead = "d|"; // d|{terminalAtNs:8BE}{jobID}
pub const prefix_queue_append = "qa|"; // qa|{queue}\x00{created_ns:8BE}{job_id}
pub const prefix_queue_cursor = "qac|"; // qac|{queue}
pub const prefix_global_rate_limit = "gl|"; // gl|{fetched_ns:8BE}{random:8BE}
pub const key_global_config = "g|rl"; // singleton: [rate:u32LE][window_ms:u32LE]
pub const prefix_ns_rate_limit = "nl|"; // nl|{namespace}\x00{fetched_ns:8BE}{random:8BE}

// Read indexes (for HTTP/UI reads — written by handlers on state transitions)
pub const prefix_job_time = "jt|"; // jt|{inv_created_ns:8BE}{job_id}
pub const prefix_job_queue = "jq|"; // jq|{queue}\x00{inv_created_ns:8BE}{job_id}
pub const prefix_job_state = "js|"; // js|{state:1}{inv_created_ns:8BE}{job_id}
pub const prefix_job_queue_state = "jqs|"; // jqs|{queue}\x00{state:1}{inv_created_ns:8BE}{job_id}
pub const prefix_tag_queue = "tq|"; // tq|{queue}\x00{tag_key}\x00{tag_value}\x00{job_id}

// Enterprise prefixes
pub const prefix_ent_ns = "ent_ns|";
pub const prefix_ent_role = "ent_role|";
pub const prefix_ent_apikey = "ent_apikey|";
pub const prefix_ent_webhook = "ent_wh|";
pub const prefix_ent_sso = "ent_sso|";
pub const prefix_ent_audit = "ent_audit|";
pub const prefix_ent_approval_policy = "ent_ap|";
pub const prefix_ent_ns_rate_limit = "ent_nsrl|";

const sep: u8 = 0x00;

/// Maximum key buffer size. Sufficient for any key we encode.
pub const max_key_len = 512;

/// Key buffer type — stack-allocated, no heap.
pub const KeyBuf = [max_key_len]u8;

// ============================================================================
// Encoding helpers
// ============================================================================

fn putU8(buf: []u8, pos: usize, v: u8) usize {
    buf[pos] = v;
    return pos + 1;
}

fn putU32BE(buf: []u8, pos: usize, v: u32) usize {
    std.mem.writeInt(u32, buf[pos..][0..4], v, .big);
    return pos + 4;
}

fn putU64BE(buf: []u8, pos: usize, v: u64) usize {
    std.mem.writeInt(u64, buf[pos..][0..8], v, .big);
    return pos + 8;
}

pub fn getU32BE(data: []const u8) u32 {
    return std.mem.readInt(u32, data[0..4], .big);
}

pub fn getU64BE(data: []const u8) u64 {
    return std.mem.readInt(u64, data[0..8], .big);
}

fn copyPrefix(buf: []u8, prefix: []const u8) usize {
    @memcpy(buf[0..prefix.len], prefix);
    return prefix.len;
}

fn copyStr(buf: []u8, pos: usize, s: []const u8) usize {
    @memcpy(buf[pos..][0..s.len], s);
    return pos + s.len;
}

// ============================================================================
// Key Builders
// ============================================================================

/// j|{job_id}
pub fn jobKey(buf: *KeyBuf, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// jp|{job_id}
pub fn jobPayloadKey(buf: *KeyBuf, job_id: []const u8) []const u8 {
    assert.check(job_id.len > 0, "jobPayloadKey: empty jobID", .{});
    var pos = copyPrefix(buf, prefix_job_payload);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// je|{job_id}\x00{attempt:4BE}
pub fn jobErrorKey(buf: *KeyBuf, job_id: []const u8, attempt: u32) []const u8 {
    var pos = copyPrefix(buf, prefix_job_error);
    pos = copyStr(buf, pos, job_id);
    pos = putU8(buf, pos, sep);
    pos = putU32BE(buf, pos, attempt);
    return buf[0..pos];
}

/// je|{job_id}\x00
pub fn jobErrorPrefix(buf: *KeyBuf, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_error);
    pos = copyStr(buf, pos, job_id);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// p|{queue}\x00{255-priority:1B}{created_ns:8BE}{job_id}
pub fn pendingKey(buf: *KeyBuf, queue: []const u8, priority: u8, created_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_pending);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU8(buf, pos, 255 - priority); // invert: higher priority sorts first
    pos = putU64BE(buf, pos, created_ns);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// p|{queue}\x00
pub fn pendingPrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_pending);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// a|{queue}\x00{job_id}
pub fn activeKey(buf: *KeyBuf, queue: []const u8, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_active);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// a|{queue}\x00
pub fn activePrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_active);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// s|{queue}\x00{scheduled_ns:8BE}{job_id}
pub fn scheduledKey(buf: *KeyBuf, queue: []const u8, scheduled_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_scheduled);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU64BE(buf, pos, scheduled_ns);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// s|{queue}\x00
pub fn scheduledScanPrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_scheduled);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// r|{queue}\x00{retry_ns:8BE}{job_id}
pub fn retryingKey(buf: *KeyBuf, queue: []const u8, retry_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_retrying);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU64BE(buf, pos, retry_ns);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// r|{queue}\x00
pub fn retryingScanPrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_retrying);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// qc|{queue}
pub fn queueConfigKey(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_queue_config);
    pos = copyStr(buf, pos, queue);
    return buf[0..pos];
}

/// qn|{queue}
pub fn queueNameKey(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_queue_name);
    pos = copyStr(buf, pos, queue);
    return buf[0..pos];
}

/// u|{queue}\x00{unique_key}
pub fn uniqueKey(buf: *KeyBuf, queue: []const u8, unique_key: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_unique);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, unique_key);
    return buf[0..pos];
}

/// u|{queue}\x00
pub fn uniquePrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_unique);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// Encode unique lock value: {job_id}|{expires_ns:8BE}
pub fn encodeUniqueValue(buf: *KeyBuf, job_id: []const u8, expires_ns: u64) []const u8 {
    var pos = copyStr(buf, 0, job_id);
    pos = putU8(buf, pos, '|');
    pos = putU64BE(buf, pos, expires_ns);
    return buf[0..pos];
}

/// Decode unique lock value: {job_id}|{expires_ns:8BE}
pub fn decodeUniqueValue(val: []const u8) struct { job_id: []const u8, expires_ns: u64 } {
    // Find last '|' — job IDs don't contain '|'
    if (val.len < 9) return .{ .job_id = val, .expires_ns = 0 };
    var i: usize = val.len - 9;
    while (true) {
        if (val[i] == '|') {
            return .{
                .job_id = val[0..i],
                .expires_ns = getU64BE(val[i + 1 ..]),
            };
        }
        if (i == 0) break;
        i -= 1;
    }
    return .{ .job_id = val, .expires_ns = 0 };
}

/// l|{queue}\x00{fetched_ns:8BE}{random:8BE}
pub fn rateLimitKey(buf: *KeyBuf, queue: []const u8, fetched_ns: u64, random: u64) []const u8 {
    var pos = copyPrefix(buf, prefix_rate_limit);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU64BE(buf, pos, fetched_ns);
    pos = putU64BE(buf, pos, random);
    return buf[0..pos];
}

/// l|{queue}\x00
pub fn rateLimitPrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_rate_limit);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// l|{queue}\x00{windowStartNs:8BE}
pub fn rateLimitWindowStart(buf: *KeyBuf, queue: []const u8, window_start_ns: u64) []const u8 {
    var pos = copyPrefix(buf, prefix_rate_limit);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU64BE(buf, pos, window_start_ns);
    return buf[0..pos];
}

// ============================================================================
// Global rate limit keys
// ============================================================================

/// gl|{fetched_ns:8BE}{random:8BE}
pub fn globalRateLimitKey(buf: *KeyBuf, fetched_ns: u64, random: u64) []const u8 {
    var pos = copyPrefix(buf, prefix_global_rate_limit);
    pos = putU64BE(buf, pos, fetched_ns);
    pos = putU64BE(buf, pos, random);
    return buf[0..pos];
}

/// gl|
pub fn globalRateLimitPrefix(buf: *KeyBuf) []const u8 {
    const p = prefix_global_rate_limit;
    @memcpy(buf[0..p.len], p);
    return buf[0..p.len];
}

/// gl|{windowStartNs:8BE}
pub fn globalRateLimitWindowStart(buf: *KeyBuf, window_start_ns: u64) []const u8 {
    var pos = copyPrefix(buf, prefix_global_rate_limit);
    pos = putU64BE(buf, pos, window_start_ns);
    return buf[0..pos];
}

/// g|rl (singleton)
pub fn globalConfigKey(buf: *KeyBuf) []const u8 {
    const k = key_global_config;
    @memcpy(buf[0..k.len], k);
    return buf[0..k.len];
}

// ============================================================================
// Namespace rate limit keys
// ============================================================================

/// nl|{namespace}\x00{fetched_ns:8BE}{random:8BE}
pub fn nsRateLimitKey(buf: *KeyBuf, namespace: []const u8, fetched_ns: u64, random: u64) []const u8 {
    var pos = copyPrefix(buf, prefix_ns_rate_limit);
    pos = copyStr(buf, pos, namespace);
    pos = putU8(buf, pos, sep);
    pos = putU64BE(buf, pos, fetched_ns);
    pos = putU64BE(buf, pos, random);
    return buf[0..pos];
}

/// nl|{namespace}\x00
pub fn nsRateLimitPrefix(buf: *KeyBuf, namespace: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_ns_rate_limit);
    pos = copyStr(buf, pos, namespace);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// nl|{namespace}\x00{windowStartNs:8BE}
pub fn nsRateLimitWindowStart(buf: *KeyBuf, namespace: []const u8, window_start_ns: u64) []const u8 {
    var pos = copyPrefix(buf, prefix_ns_rate_limit);
    pos = copyStr(buf, pos, namespace);
    pos = putU8(buf, pos, sep);
    pos = putU64BE(buf, pos, window_start_ns);
    return buf[0..pos];
}

/// b|{batch_id}
pub fn batchKey(buf: *KeyBuf, batch_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_batch);
    pos = copyStr(buf, pos, batch_id);
    return buf[0..pos];
}

/// w|{worker_id}
pub fn workerKey(buf: *KeyBuf, worker_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_worker);
    pos = copyStr(buf, pos, worker_id);
    return buf[0..pos];
}

/// sc|{cron_id}
pub fn cronKey(buf: *KeyBuf, cron_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_cron);
    pos = copyStr(buf, pos, cron_id);
    return buf[0..pos];
}

/// cn|{name}
pub fn cronNameKey(buf: *KeyBuf, name: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_cron_name);
    pos = copyStr(buf, pos, name);
    return buf[0..pos];
}

/// qa|{queue}\x00{created_ns:8BE}{job_id}
pub fn queueAppendKey(buf: *KeyBuf, queue: []const u8, created_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_queue_append);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU64BE(buf, pos, created_ns);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// qa|{queue}\x00
pub fn queueAppendPrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_queue_append);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// qac|{queue}
pub fn queueCursorKey(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_queue_cursor);
    pos = copyStr(buf, pos, queue);
    return buf[0..pos];
}

/// ev|{seq:8BE}
pub fn eventLogKey(buf: *KeyBuf, seq: u64) []const u8 {
    var pos = copyPrefix(buf, prefix_event_log);
    pos = putU64BE(buf, pos, seq);
    return buf[0..pos];
}

/// evc| (singleton)
pub fn eventCursorKey(buf: *KeyBuf) []const u8 {
    const k = key_event_cursor;
    @memcpy(buf[0..k.len], k);
    return buf[0..k.len];
}

/// Extract seq from ev|{seq:8BE} key. Returns null if key doesn't match.
pub fn eventSeqFromKey(k: []const u8) ?u64 {
    const p = prefix_event_log;
    if (k.len != p.len + 8) return null;
    if (!std.mem.startsWith(u8, k, p)) return null;
    return getU64BE(k[p.len..]);
}

/// bg|{scope}\x00{target}
pub fn budgetKey(buf: *KeyBuf, scope: []const u8, target: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_budget);
    pos = copyStr(buf, pos, scope);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, target);
    return buf[0..pos];
}

/// pv|{name}
pub fn providerKey(buf: *KeyBuf, name: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_provider);
    pos = copyStr(buf, pos, name);
    return buf[0..pos];
}

/// qp|{queue}
pub fn queueProviderKey(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_queue_prov);
    pos = copyStr(buf, pos, queue);
    return buf[0..pos];
}

/// x|{expireAtNs:8BE}{jobID}
pub fn expireKey(buf: *KeyBuf, expire_at_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_expire);
    pos = putU64BE(buf, pos, expire_at_ns);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// d|{terminalAtNs:8BE}{jobID}
pub fn deadKey(buf: *KeyBuf, terminal_at_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_dead);
    pos = putU64BE(buf, pos, terminal_at_ns);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

// ============================================================================
// Read Index Key Builders
// ============================================================================

/// Invert timestamp so forward iteration = newest first.
pub fn invertTimestamp(ns: u64) u64 {
    return std.math.maxInt(u64) - ns;
}

/// Recover original timestamp from inverted value.
pub fn recoverTimestamp(inv: u64) u64 {
    return std.math.maxInt(u64) - inv;
}

/// jt|{inv_created_ns:8BE}{job_id}
pub fn jobTimeKey(buf: *KeyBuf, created_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_time);
    pos = putU64BE(buf, pos, invertTimestamp(created_ns));
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// jq|{queue}\x00{inv_created_ns:8BE}{job_id}
pub fn jobQueueKey(buf: *KeyBuf, queue: []const u8, created_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_queue);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU64BE(buf, pos, invertTimestamp(created_ns));
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// jq|{queue}\x00
pub fn jobQueuePrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_queue);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// js|{state:1}{inv_created_ns:8BE}{job_id}
pub fn jobStateKey(buf: *KeyBuf, state: u8, created_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_state);
    pos = putU8(buf, pos, state);
    pos = putU64BE(buf, pos, invertTimestamp(created_ns));
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// js|{state:1}
pub fn jobStatePrefix(buf: *KeyBuf, state: u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_state);
    pos = putU8(buf, pos, state);
    return buf[0..pos];
}

/// jqs|{queue}\x00{state:1}{inv_created_ns:8BE}{job_id}
pub fn jobQueueStateKey(buf: *KeyBuf, queue: []const u8, state: u8, created_ns: u64, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_queue_state);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU8(buf, pos, state);
    pos = putU64BE(buf, pos, invertTimestamp(created_ns));
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// jqs|{queue}\x00{state:1}
pub fn jobQueueStatePrefix(buf: *KeyBuf, queue: []const u8, state: u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_queue_state);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = putU8(buf, pos, state);
    return buf[0..pos];
}

/// jqs|{queue}\x00
pub fn jobQueueStateQueuePrefix(buf: *KeyBuf, queue: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_job_queue_state);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// tq|{queue}\x00{tag_key}\x00{tag_value}\x00{job_id}
pub fn tagQueueKey(buf: *KeyBuf, queue: []const u8, tag_key: []const u8, tag_value: []const u8, job_id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_tag_queue);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, tag_key);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, tag_value);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, job_id);
    return buf[0..pos];
}

/// tq|{queue}\x00{tag_key}\x00{tag_value}\x00
pub fn tagQueuePrefix(buf: *KeyBuf, queue: []const u8, tag_key: []const u8, tag_value: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix_tag_queue);
    pos = copyStr(buf, pos, queue);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, tag_key);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, tag_value);
    pos = putU8(buf, pos, sep);
    return buf[0..pos];
}

/// Extract job ID from a jt| key: jt|{inv_ts:8BE}{job_id}
pub fn jobIdFromTimeKey(k: []const u8) []const u8 {
    return k[prefix_job_time.len + 8 ..];
}

/// Extract job ID from a jq| key: jq|{queue}\x00{inv_ts:8BE}{job_id}
pub fn jobIdFromQueueKey(k: []const u8) ?[]const u8 {
    const start = prefix_job_queue.len;
    const sep_pos = std.mem.indexOfScalarPos(u8, k, start, sep) orelse return null;
    return k[sep_pos + 1 + 8 ..]; // skip sep + 8-byte inv_ts
}

/// Extract job ID from a js| key: js|{state:1}{inv_ts:8BE}{job_id}
pub fn jobIdFromStateKey(k: []const u8) []const u8 {
    return k[prefix_job_state.len + 1 + 8 ..];
}

/// Extract job ID from a jqs| key: jqs|{queue}\x00{state:1}{inv_ts:8BE}{job_id}
pub fn jobIdFromQueueStateKey(k: []const u8) ?[]const u8 {
    const start = prefix_job_queue_state.len;
    const sep_pos = std.mem.indexOfScalarPos(u8, k, start, sep) orelse return null;
    return k[sep_pos + 1 + 1 + 8 ..]; // skip sep + state + 8-byte inv_ts
}

/// Extract job ID from a tq| key: tq|{queue}\x00{tag_key}\x00{tag_value}\x00{job_id}
pub fn jobIdFromTagQueueKey(k: []const u8) ?[]const u8 {
    const start = prefix_tag_queue.len;
    // Find first sep (after queue)
    const sep1 = std.mem.indexOfScalarPos(u8, k, start, sep) orelse return null;
    // Find second sep (after tag_key)
    const sep2 = std.mem.indexOfScalarPos(u8, k, sep1 + 1, sep) orelse return null;
    // Find third sep (after tag_value)
    const sep3 = std.mem.indexOfScalarPos(u8, k, sep2 + 1, sep) orelse return null;
    return k[sep3 + 1 ..];
}

/// Compute the key just past all keys with the given prefix.
/// Returns the end bound for range scans.
pub fn prefixEnd(buf: *KeyBuf, prefix: []const u8) ?[]const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    var i: usize = prefix.len;
    while (i > 0) {
        i -= 1;
        buf[i] +%= 1;
        if (buf[i] != 0) {
            return buf[0 .. i + 1];
        }
    }
    return null; // prefix is all 0xFF
}

/// Enterprise setting key: {prefix}{id}
pub fn entSettingKey(buf: *KeyBuf, prefix: []const u8, id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix);
    pos = copyStr(buf, pos, id);
    return buf[0..pos];
}

/// Enterprise scoped setting key: {prefix}{scope}\x00{id}
pub fn entSettingScopeKey(buf: *KeyBuf, prefix: []const u8, scope: []const u8, id: []const u8) []const u8 {
    var pos = copyPrefix(buf, prefix);
    pos = copyStr(buf, pos, scope);
    pos = putU8(buf, pos, sep);
    pos = copyStr(buf, pos, id);
    return buf[0..pos];
}

// ============================================================================
// Tests
// ============================================================================

test "jobKey roundtrip" {
    var buf: KeyBuf = undefined;
    const k = jobKey(&buf, "abc123");
    try std.testing.expectEqualStrings("j|abc123", k);
}

test "jobPayloadKey" {
    var buf: KeyBuf = undefined;
    const k = jobPayloadKey(&buf, "xyz");
    try std.testing.expectEqualStrings("jp|xyz", k);
}

test "pendingKey sort order" {
    var buf1: KeyBuf = undefined;
    var buf2: KeyBuf = undefined;
    // Higher priority (100) should sort before lower (50) because we invert
    const k1 = pendingKey(&buf1, "q", 100, 1000, "j1");
    const k2 = pendingKey(&buf2, "q", 50, 1000, "j2");
    try std.testing.expect(std.mem.order(u8, k1, k2) == .lt);
}

test "pendingKey same priority sorts by created_ns" {
    var buf1: KeyBuf = undefined;
    var buf2: KeyBuf = undefined;
    const k1 = pendingKey(&buf1, "q", 50, 1000, "j1");
    const k2 = pendingKey(&buf2, "q", 50, 2000, "j2");
    try std.testing.expect(std.mem.order(u8, k1, k2) == .lt);
}

test "activeKey" {
    var buf: KeyBuf = undefined;
    const k = activeKey(&buf, "default", "job-1");
    try std.testing.expectEqualStrings("a|default\x00job-1", k);
}

test "scheduledKey" {
    var buf: KeyBuf = undefined;
    const k = scheduledKey(&buf, "q", 5000, "j1");
    try std.testing.expectEqualStrings(prefix_scheduled, k[0..prefix_scheduled.len]);
    try std.testing.expectEqual(@as(u8, sep), k[prefix_scheduled.len + 1]);
}

test "uniqueValue roundtrip" {
    var buf: KeyBuf = undefined;
    const val = encodeUniqueValue(&buf, "job-42", 9999);
    const decoded = decodeUniqueValue(val);
    try std.testing.expectEqualStrings("job-42", decoded.job_id);
    try std.testing.expectEqual(@as(u64, 9999), decoded.expires_ns);
}

test "prefixEnd" {
    var buf: KeyBuf = undefined;
    const end = prefixEnd(&buf, "j|").?;
    try std.testing.expectEqualStrings("j}", end);
}

test "prefixEnd all 0xFF returns null" {
    var buf: KeyBuf = undefined;
    const result = prefixEnd(&buf, &[_]u8{ 0xFF, 0xFF });
    try std.testing.expect(result == null);
}

test "eventSeqFromKey" {
    var buf: KeyBuf = undefined;
    const k = eventLogKey(&buf, 42);
    const seq = eventSeqFromKey(k).?;
    try std.testing.expectEqual(@as(u64, 42), seq);
}

test "eventSeqFromKey rejects wrong prefix" {
    const result = eventSeqFromKey("j|somekey");
    try std.testing.expect(result == null);
}

test "jobErrorKey" {
    var buf: KeyBuf = undefined;
    const k = jobErrorKey(&buf, "job1", 3);
    // Should start with prefix, contain the job id, sep, then 4 bytes
    try std.testing.expect(std.mem.startsWith(u8, k, prefix_job_error));
    try std.testing.expectEqual(prefix_job_error.len + 4 + 1 + 4, k.len);
}

test "budgetKey" {
    var buf: KeyBuf = undefined;
    const k = budgetKey(&buf, "queue", "default");
    try std.testing.expectEqualStrings("bg|queue\x00default", k);
}

test "deadKey" {
    var buf: KeyBuf = undefined;
    const k = deadKey(&buf, 1000, "j1");
    try std.testing.expect(std.mem.startsWith(u8, k, prefix_dead));
}

test "rateLimitKey" {
    var buf: KeyBuf = undefined;
    const k = rateLimitKey(&buf, "q", 5000, 42);
    try std.testing.expect(std.mem.startsWith(u8, k, prefix_rate_limit));
    // prefix + queue + sep + 8 + 8 = 2 + 1 + 1 + 8 + 8 = 20
    try std.testing.expectEqual(prefix_rate_limit.len + 1 + 1 + 8 + 8, k.len);
}

test "invertTimestamp roundtrip" {
    const ts: u64 = 1711670400_000_000_000;
    const inv = invertTimestamp(ts);
    try std.testing.expectEqual(ts, recoverTimestamp(inv));
}

test "invertTimestamp newer sorts first" {
    var buf1: KeyBuf = undefined;
    var buf2: KeyBuf = undefined;
    const older: u64 = 1000;
    const newer: u64 = 2000;
    const k1 = jobTimeKey(&buf1, newer, "j1");
    const k2 = jobTimeKey(&buf2, older, "j2");
    // Newer timestamp should sort first (smaller inverted value)
    try std.testing.expect(std.mem.order(u8, k1, k2) == .lt);
}

test "jobTimeKey extract job ID" {
    var buf: KeyBuf = undefined;
    const k = jobTimeKey(&buf, 5000, "my-job");
    const id = jobIdFromTimeKey(k);
    try std.testing.expectEqualStrings("my-job", id);
}

test "jobQueueKey and prefix" {
    var buf: KeyBuf = undefined;
    const k = jobQueueKey(&buf, "default", 5000, "j1");
    try std.testing.expect(std.mem.startsWith(u8, k, prefix_job_queue));
    const id = jobIdFromQueueKey(k).?;
    try std.testing.expectEqualStrings("j1", id);
}

test "jobStateKey and prefix" {
    var buf1: KeyBuf = undefined;
    var buf2: KeyBuf = undefined;
    const k = jobStateKey(&buf1, 0, 5000, "j1");
    try std.testing.expect(std.mem.startsWith(u8, k, prefix_job_state));
    const id = jobIdFromStateKey(k);
    try std.testing.expectEqualStrings("j1", id);
    // Different states sort into different ranges
    const k_s0 = jobStateKey(&buf1, 0, 5000, "j1");
    const k_s1 = jobStateKey(&buf2, 1, 5000, "j1");
    try std.testing.expect(std.mem.order(u8, k_s0, k_s1) == .lt);
}

test "jobQueueStateKey extract job ID" {
    var buf: KeyBuf = undefined;
    const k = jobQueueStateKey(&buf, "payments", 2, 5000, "job-42");
    const id = jobIdFromQueueStateKey(k).?;
    try std.testing.expectEqualStrings("job-42", id);
}

test "tagQueueKey extract job ID" {
    var buf: KeyBuf = undefined;
    const k = tagQueueKey(&buf, "payments", "customer_id", "acme", "job-99");
    try std.testing.expect(std.mem.startsWith(u8, k, prefix_tag_queue));
    const id = jobIdFromTagQueueKey(k).?;
    try std.testing.expectEqualStrings("job-99", id);
}
