//! KV read layer — typed queries directly from Talon KV store.
//!
//! Replaces sqlite_read.zig. All reads create a temporary WriteBatch
//! (which sees committed state), iterate or get, then close.
//! No SQLite, no mirror, no buffer — reads are always fresh.

const std = @import("std");
const kv = @import("kv.zig");
const keys = @import("keys.zig");
const codec = @import("codec.zig");
const types = @import("types.zig");

// ============================================================================
// Result types (same shapes as sqlite_read.zig for API compat)
// ============================================================================

pub const JobRow = struct {
    id: [128]u8 = undefined,
    id_len: u8 = 0,
    queue: [128]u8 = undefined,
    queue_len: u8 = 0,
    state: [16]u8 = undefined,
    state_len: u8 = 0,
    priority: i32 = 2,
    attempt: i32 = 0,
    max_retries: i32 = 0,
    worker_id: [128]u8 = undefined,
    worker_id_len: u8 = 0,
    hostname: [128]u8 = undefined,
    hostname_len: u8 = 0,
    tags: [512]u8 = undefined,
    tags_len: u16 = 0,
    checkpoint: [4096]u8 = undefined,
    checkpoint_len: u16 = 0,
    result: [4096]u8 = undefined,
    result_len: u16 = 0,
    hold_reason: [256]u8 = undefined,
    hold_reason_len: u8 = 0,
    error_msg: [512]u8 = undefined,
    error_msg_len: u16 = 0,
    batch_id: [128]u8 = undefined,
    batch_id_len: u8 = 0,
    unique_key: [128]u8 = undefined,
    unique_key_len: u8 = 0,
    parent_id: [128]u8 = undefined,
    parent_id_len: u8 = 0,
    chain_id: [128]u8 = undefined,
    chain_id_len: u8 = 0,
    chain_step: i32 = 0,
    group_key: [128]u8 = undefined,
    group_key_len: u8 = 0,
    created_at: [32]u8 = undefined,
    created_at_len: u8 = 0,
    started_at: [32]u8 = undefined,
    started_at_len: u8 = 0,
    completed_at: [32]u8 = undefined,
    completed_at_len: u8 = 0,
    failed_at: [32]u8 = undefined,
    failed_at_len: u8 = 0,
    scheduled_at: [32]u8 = undefined,
    scheduled_at_len: u8 = 0,
    lease_expires_at: [32]u8 = undefined,
    lease_expires_at_len: u8 = 0,
    retry_backoff: [16]u8 = undefined,
    retry_backoff_len: u8 = 0,
    retry_base_delay_ms: i32 = 0,
    retry_max_delay_ms: i32 = 0,
    progress: [4096]u8 = undefined,
    progress_len: u16 = 0,
    expire_at: [32]u8 = undefined,
    expire_at_len: u8 = 0,

    pub fn idSlice(self: *const JobRow) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn queueSlice(self: *const JobRow) []const u8 {
        return self.queue[0..self.queue_len];
    }
    pub fn stateSlice(self: *const JobRow) []const u8 {
        return self.state[0..self.state_len];
    }
    pub fn workerIdSlice(self: *const JobRow) []const u8 {
        return self.worker_id[0..self.worker_id_len];
    }
    pub fn hostnameSlice(self: *const JobRow) []const u8 {
        return self.hostname[0..self.hostname_len];
    }
    pub fn tagsSlice(self: *const JobRow) []const u8 {
        return self.tags[0..self.tags_len];
    }
    pub fn checkpointSlice(self: *const JobRow) []const u8 {
        return self.checkpoint[0..self.checkpoint_len];
    }
    pub fn resultSlice(self: *const JobRow) []const u8 {
        return self.result[0..self.result_len];
    }
    pub fn holdReasonSlice(self: *const JobRow) []const u8 {
        return self.hold_reason[0..self.hold_reason_len];
    }
    pub fn errorMsgSlice(self: *const JobRow) []const u8 {
        return self.error_msg[0..self.error_msg_len];
    }
    pub fn batchIdSlice(self: *const JobRow) []const u8 {
        return self.batch_id[0..self.batch_id_len];
    }
    pub fn uniqueKeySlice(self: *const JobRow) []const u8 {
        return self.unique_key[0..self.unique_key_len];
    }
    pub fn parentIdSlice(self: *const JobRow) []const u8 {
        return self.parent_id[0..self.parent_id_len];
    }
    pub fn chainIdSlice(self: *const JobRow) []const u8 {
        return self.chain_id[0..self.chain_id_len];
    }
    pub fn groupKeySlice(self: *const JobRow) []const u8 {
        return self.group_key[0..self.group_key_len];
    }
    pub fn createdAtSlice(self: *const JobRow) []const u8 {
        return self.created_at[0..self.created_at_len];
    }
    pub fn startedAtSlice(self: *const JobRow) []const u8 {
        return self.started_at[0..self.started_at_len];
    }
    pub fn completedAtSlice(self: *const JobRow) []const u8 {
        return self.completed_at[0..self.completed_at_len];
    }
    pub fn failedAtSlice(self: *const JobRow) []const u8 {
        return self.failed_at[0..self.failed_at_len];
    }
    pub fn scheduledAtSlice(self: *const JobRow) []const u8 {
        return self.scheduled_at[0..self.scheduled_at_len];
    }
    pub fn leaseExpiresAtSlice(self: *const JobRow) []const u8 {
        return self.lease_expires_at[0..self.lease_expires_at_len];
    }
    pub fn retryBackoffSlice(self: *const JobRow) []const u8 {
        return self.retry_backoff[0..self.retry_backoff_len];
    }
    pub fn progressSlice(self: *const JobRow) []const u8 {
        return self.progress[0..self.progress_len];
    }
    pub fn expireAtSlice(self: *const JobRow) []const u8 {
        return self.expire_at[0..self.expire_at_len];
    }
};

pub const QueueStats = struct {
    name: [128]u8 = undefined,
    name_len: u8 = 0,
    pending: i32 = 0,
    active: i32 = 0,
    retrying: i32 = 0,
    scheduled: i32 = 0,
    completed: i32 = 0,
    dead: i32 = 0,
    held: i32 = 0,
    paused: bool = false,
    oldest_pending_at: [32]u8 = undefined,
    oldest_pending_at_len: u8 = 0,

    pub fn nameSlice(self: *const QueueStats) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn oldestPendingAtSlice(self: *const QueueStats) []const u8 {
        return self.oldest_pending_at[0..self.oldest_pending_at_len];
    }
};

pub const WorkerRow = struct {
    id: [128]u8 = undefined,
    id_len: u8 = 0,
    hostname: [128]u8 = undefined,
    hostname_len: u8 = 0,
    queues: [512]u8 = undefined,
    queues_len: u16 = 0,
    last_heartbeat: [32]u8 = undefined,
    last_heartbeat_len: u8 = 0,
    started_at: [32]u8 = undefined,
    started_at_len: u8 = 0,

    pub fn idSlice(self: *const WorkerRow) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn hostnameSlice(self: *const WorkerRow) []const u8 {
        return self.hostname[0..self.hostname_len];
    }
    pub fn queuesSlice(self: *const WorkerRow) []const u8 {
        return self.queues[0..self.queues_len];
    }
    pub fn lastHeartbeatSlice(self: *const WorkerRow) []const u8 {
        return self.last_heartbeat[0..self.last_heartbeat_len];
    }
    pub fn startedAtSlice(self: *const WorkerRow) []const u8 {
        return self.started_at[0..self.started_at_len];
    }
};

pub const CronRow = struct {
    id: [128]u8 = undefined,
    id_len: u8 = 0,
    name: [128]u8 = undefined,
    name_len: u8 = 0,
    queue: [128]u8 = undefined,
    queue_len: u8 = 0,
    schedule: [64]u8 = undefined,
    schedule_len: u8 = 0,
    enabled: bool = true,

    pub fn idSlice(self: *const CronRow) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const CronRow) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn queueSlice(self: *const CronRow) []const u8 {
        return self.queue[0..self.queue_len];
    }
    pub fn scheduleSlice(self: *const CronRow) []const u8 {
        return self.schedule[0..self.schedule_len];
    }
};

pub const JobError = struct {
    attempt: i32 = 0,
    error_msg: [512]u8 = undefined,
    error_msg_len: u16 = 0,
    created_at: [32]u8 = undefined,
    created_at_len: u8 = 0,

    pub fn errorSlice(self: *const JobError) []const u8 {
        return self.error_msg[0..self.error_msg_len];
    }
};

pub const BudgetRow = struct {
    scope: [64]u8 = undefined,
    scope_len: u8 = 0,
    target: [64]u8 = undefined,
    target_len: u8 = 0,
    daily_usd: f64 = 0,
    per_job_usd: f64 = 0,
    on_exceed: [16]u8 = undefined,
    on_exceed_len: u8 = 0,
    created_at: [32]u8 = undefined,
    created_at_len: u8 = 0,

    pub fn scopeSlice(self: *const BudgetRow) []const u8 {
        return self.scope[0..self.scope_len];
    }
    pub fn targetSlice(self: *const BudgetRow) []const u8 {
        return self.target[0..self.target_len];
    }
    pub fn onExceedSlice(self: *const BudgetRow) []const u8 {
        return self.on_exceed[0..self.on_exceed_len];
    }
    pub fn createdAtSlice(self: *const BudgetRow) []const u8 {
        return self.created_at[0..self.created_at_len];
    }
};

pub const ApiKeyRow = struct {
    key_hash: [64]u8 = undefined,
    key_hash_len: u8 = 0,
    name: [128]u8 = undefined,
    name_len: u8 = 0,
    role: [32]u8 = undefined,
    role_len: u8 = 0,
    enabled: bool = true,
    expires_at: [32]u8 = undefined,
    expires_at_len: u8 = 0,
    created_at: [32]u8 = undefined,
    created_at_len: u8 = 0,

    pub fn keyHashSlice(self: *const ApiKeyRow) []const u8 {
        return self.key_hash[0..self.key_hash_len];
    }
    pub fn nameSlice(self: *const ApiKeyRow) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn roleSlice(self: *const ApiKeyRow) []const u8 {
        return self.role[0..self.role_len];
    }
    pub fn expiresAtSlice(self: *const ApiKeyRow) []const u8 {
        return self.expires_at[0..self.expires_at_len];
    }
    pub fn createdAtSlice(self: *const ApiKeyRow) []const u8 {
        return self.created_at[0..self.created_at_len];
    }
};

pub const WebhookRow = struct {
    id: [64]u8 = undefined,
    id_len: u8 = 0,
    url: [512]u8 = undefined,
    url_len: u16 = 0,
    queue_filter: [64]u8 = undefined,
    queue_filter_len: u8 = 0,
    events: [128]u8 = undefined,
    events_len: u8 = 0,
    enabled: bool = true,
    created_at: [32]u8 = undefined,
    created_at_len: u8 = 0,

    pub fn idSlice(self: *const WebhookRow) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn urlSlice(self: *const WebhookRow) []const u8 {
        return self.url[0..self.url_len];
    }
    pub fn queueFilterSlice(self: *const WebhookRow) []const u8 {
        return self.queue_filter[0..self.queue_filter_len];
    }
    pub fn eventsSlice(self: *const WebhookRow) []const u8 {
        return self.events[0..self.events_len];
    }
    pub fn createdAtSlice(self: *const WebhookRow) []const u8 {
        return self.created_at[0..self.created_at_len];
    }
};

pub const AuditEntryRow = struct {
    op: [64]u8 = undefined,
    op_len: u8 = 0,
    target: [256]u8 = undefined,
    target_len: u16 = 0,
    actor: [128]u8 = undefined,
    actor_len: u8 = 0,
    count: u32 = 0,
    ts: u64 = 0,
    created_at: [32]u8 = undefined,
    created_at_len: u8 = 0,

    pub fn opSlice(self: *const AuditEntryRow) []const u8 {
        return self.op[0..self.op_len];
    }
    pub fn targetSlice(self: *const AuditEntryRow) []const u8 {
        return self.target[0..self.target_len];
    }
    pub fn actorSlice(self: *const AuditEntryRow) []const u8 {
        return self.actor[0..self.actor_len];
    }
    pub fn createdAtSlice(self: *const AuditEntryRow) []const u8 {
        return self.created_at[0..self.created_at_len];
    }
};

pub const QueryResult = struct {
    count: u32 = 0,
    has_more: bool = false,
    next_cursor: [max_cursor_len]u8 = undefined,
    next_cursor_len: u16 = 0,

    pub fn cursorSlice(self: *const QueryResult) ?[]const u8 {
        if (self.next_cursor_len == 0) return null;
        return self.next_cursor[0..self.next_cursor_len];
    }
};

const max_cursor_len: u16 = 256;

// ============================================================================
// Reader
// ============================================================================

pub const Reader = struct {
    store: *kv.Store,

    pub fn init(store: *kv.Store) Reader {
        return .{ .store = store };
    }

    // ====================================================================
    // Jobs
    // ====================================================================

    /// Get a single job by ID.
    pub fn getJob(self: *Reader, job_id: []const u8) ?JobRow {
        var batch = self.store.newBatch();
        defer batch.close();

        var key_buf: keys.KeyBuf = undefined;
        const val = batch.get(keys.jobKey(&key_buf, job_id)) orelse return null;
        const job = codec.decodeJob(val);
        return jobToRow(&job);
    }

    /// Get job payload.
    pub fn getJobPayload(self: *Reader, job_id: []const u8, out: []u8) ?[]const u8 {
        var batch = self.store.newBatch();
        defer batch.close();

        var key_buf: keys.KeyBuf = undefined;
        const val = batch.get(keys.jobPayloadKey(&key_buf, job_id)) orelse return null;
        const len = @min(val.len, out.len);
        @memcpy(out[0..len], val[0..len]);
        return out[0..len];
    }

    /// Get errors for a job.
    pub fn getJobErrors(self: *Reader, job_id: []const u8, results: []JobError) u32 {
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const lower = keys.jobErrorPrefix(&lower_buf, job_id);
        const upper = keys.prefixEnd(&upper_buf, lower) orelse return 0;

        var iter = batch.newIter(lower, upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len) break;
            const k = iter.key();
            const v = iter.value();

            var row = JobError{};
            // Extract attempt from key: je|{job_id}\x00{attempt:4BE}
            const attempt_offset = keys.prefix_job_error.len + job_id.len + 1;
            if (k.len >= attempt_offset + 4) {
                row.attempt = @intCast(keys.getU32BE(k[attempt_offset..]));
            }
            // Value is the error message
            const len: u16 = @intCast(@min(v.len, row.error_msg.len));
            @memcpy(row.error_msg[0..len], v[0..len]);
            row.error_msg_len = len;

            results[count] = row;
            count += 1;
            if (!iter.next()) break;
        }
        return count;
    }

    /// List all jobs ordered by created_at DESC (via jt| index).
    pub fn getJobs(self: *Reader, results: []JobRow) u32 {
        var batch = self.store.newBatch();
        defer batch.close();
        return self.scanJobsByIndex(&batch, keys.prefix_job_time, results);
    }

    /// Query jobs by queue and state with cursor-based pagination.
    pub fn queryJobsByQueueState(
        self: *Reader,
        queue: ?[]const u8,
        state: ?[]const u8,
        limit: u32,
        _: u32, // offset — ignored, kept for API compat during migration
        results: []JobRow,
    ) u32 {
        var batch = self.store.newBatch();
        defer batch.close();

        const state_byte: ?u8 = if (state) |s| stateStringToByte(s) else null;
        const actual_limit = @min(limit, @as(u32, @intCast(results.len)));

        if (queue != null and state_byte != null) {
            // jqs|{queue}\x00{state}...
            var prefix_buf: keys.KeyBuf = undefined;
            const prefix = keys.jobQueueStatePrefix(&prefix_buf, queue.?, state_byte.?);
            return self.scanJobsByPrefix(&batch, prefix, actual_limit, results);
        } else if (queue != null) {
            // jq|{queue}\x00...
            var prefix_buf: keys.KeyBuf = undefined;
            const prefix = keys.jobQueuePrefix(&prefix_buf, queue.?);
            return self.scanJobsByPrefix(&batch, prefix, actual_limit, results);
        } else if (state_byte != null) {
            // js|{state}...
            var prefix_buf: keys.KeyBuf = undefined;
            const prefix = keys.jobStatePrefix(&prefix_buf, state_byte.?);
            return self.scanJobsByPrefix(&batch, prefix, actual_limit, results);
        } else {
            // All jobs by creation time
            return self.scanJobsByIndex(&batch, keys.prefix_job_time, results[0..actual_limit]);
        }
    }

    /// Count jobs in a given state (from queue stats counters).
    pub fn countJobsByState(self: *Reader, state: []const u8) i32 {
        var stats_buf: [64]QueueStats = undefined;
        const count = self.getQueueStats(&stats_buf);
        var total: i32 = 0;
        for (0..count) |i| {
            total += stateCountFromStats(&stats_buf[i], state);
        }
        return total;
    }

    /// Count jobs in a queue with a given state.
    pub fn countJobsByQueueState(self: *Reader, queue: []const u8, state: []const u8) i32 {
        var stats_buf: [64]QueueStats = undefined;
        const count = self.getQueueStats(&stats_buf);
        for (0..count) |i| {
            if (std.mem.eql(u8, stats_buf[i].nameSlice(), queue)) {
                return stateCountFromStats(&stats_buf[i], state);
            }
        }
        return 0;
    }

    // ====================================================================
    // Queues
    // ====================================================================

    /// Get queue stats from embedded counters in qc| values.
    pub fn getQueueStats(self: *Reader, results: []QueueStats) u32 {
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const p = keys.prefix_queue_config;
        @memcpy(lower_buf[0..p.len], p);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..p.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..p.len], upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len) break;
            const val = iter.value();
            const q = codec.decodeQueue(val);

            var row = QueueStats{
                .paused = q.paused,
                .pending = @intCast(q.pending_count),
                .active = @intCast(q.active_count),
                .retrying = @intCast(q.retrying_count),
                .scheduled = @intCast(q.scheduled_count),
                .completed = @intCast(q.completed_count),
                .dead = @intCast(q.dead_count),
                .held = @intCast(q.held_count),
            };
            copyField(&row.name, &row.name_len, q.name);
            results[count] = row;
            count += 1;
            if (!iter.next()) break;
        }
        return count;
    }

    // ====================================================================
    // Workers
    // ====================================================================

    pub fn getWorkers(self: *Reader, results: []WorkerRow) u32 {
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const p = keys.prefix_worker;
        @memcpy(lower_buf[0..p.len], p);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..p.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..p.len], upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len) break;
            const val = iter.value();
            const w = codec.decodeWorker(val);

            var row = WorkerRow{};
            copyField(&row.id, &row.id_len, w.id);
            if (w.hostname) |h| copyField(&row.hostname, &row.hostname_len, h);
            if (w.queues) |q| copyField16(&row.queues, &row.queues_len, q);
            formatNs(&row.last_heartbeat, &row.last_heartbeat_len, w.last_heartbeat_ns);
            formatNs(&row.started_at, &row.started_at_len, w.started_at_ns);

            results[count] = row;
            count += 1;
            if (!iter.next()) break;
        }
        return count;
    }

    pub fn countWorkers(self: *Reader) i32 {
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const p = keys.prefix_worker;
        @memcpy(lower_buf[0..p.len], p);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..p.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..p.len], upper);
        defer iter.close();

        var count: i32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            count += 1;
            if (!iter.next()) break;
        }
        return count;
    }

    // ====================================================================
    // Crons
    // ====================================================================

    pub fn getCron(self: *Reader, cron_id: []const u8) ?CronRow {
        var batch = self.store.newBatch();
        defer batch.close();

        var key_buf: keys.KeyBuf = undefined;
        const val = batch.get(keys.cronKey(&key_buf, cron_id)) orelse return null;
        const c = codec.decodeCron(val);
        return cronToRow(&c);
    }

    pub fn listCrons(self: *Reader, results: []CronRow) u32 {
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const p = keys.prefix_cron;
        @memcpy(lower_buf[0..p.len], p);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..p.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..p.len], upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len) break;
            const val = iter.value();
            const c = codec.decodeCron(val);
            results[count] = cronToRow(&c);
            count += 1;
            if (!iter.next()) break;
        }
        return count;
    }

    // ====================================================================
    // Budgets
    // ====================================================================

    pub fn listBudgets(self: *Reader, results: []BudgetRow) u32 {
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const p = keys.prefix_budget;
        @memcpy(lower_buf[0..p.len], p);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..p.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..p.len], upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len) break;
            const val = iter.value();
            const b = codec.decodeBudget(val);
            var row = BudgetRow{
                .daily_usd = b.daily_usd,
                .per_job_usd = b.per_job_usd,
            };
            copyField(&row.scope, &row.scope_len, b.scope);
            copyField(&row.target, &row.target_len, b.target);
            copyField16x(&row.on_exceed, &row.on_exceed_len, b.on_exceed);
            formatNs(&row.created_at, &row.created_at_len, b.created_at_ns);
            results[count] = row;
            count += 1;
            if (!iter.next()) break;
        }
        return count;
    }

    // ====================================================================
    // API Keys
    // ====================================================================

    pub fn listApiKeys(self: *Reader, results: []ApiKeyRow) u32 {
        return self.scanPrefix(keys.prefix_apikey, ApiKeyRow, results, apiKeyFromValue);
    }

    pub fn countEnabledApiKeys(self: *Reader) i32 {
        var key_buf: [100]ApiKeyRow = undefined;
        const count = self.listApiKeys(&key_buf);
        var enabled: i32 = 0;
        for (0..count) |i| {
            if (key_buf[i].enabled) enabled += 1;
        }
        return enabled;
    }

    pub fn getApiKeyByHash(self: *Reader, key_hash: []const u8) ?ApiKeyRow {
        var batch = self.store.newBatch();
        defer batch.close();

        var key_buf: keys.KeyBuf = undefined;
        const val = batch.get(keys.settingKey(&key_buf, keys.prefix_apikey, key_hash)) orelse return null;
        return apiKeyFromValue(val);
    }

    // ====================================================================
    // Webhooks
    // ====================================================================

    pub fn listWebhooks(self: *Reader, results: []WebhookRow) u32 {
        return self.scanPrefix(keys.prefix_webhook, WebhookRow, results, webhookFromValue);
    }

    pub fn getWebhookById(self: *Reader, webhook_id: []const u8) ?WebhookRow {
        var batch = self.store.newBatch();
        defer batch.close();

        var key_buf: keys.KeyBuf = undefined;
        const val = batch.get(keys.settingKey(&key_buf, keys.prefix_webhook, webhook_id)) orelse return null;
        return webhookFromValue(val);
    }

    // ====================================================================
    // Audit Log
    // ====================================================================

    /// List audit entries, newest first. Returns up to results.len entries.
    pub fn listAuditEntries(self: *Reader, results: []AuditEntryRow) u32 {
        const count = self.scanPrefix(keys.prefix_audit, AuditEntryRow, results, auditEntryFromValue);
        // Reverse for newest-first (forward scan gives oldest-first).
        if (count > 1) {
            var lo: u32 = 0;
            var hi: u32 = count - 1;
            while (lo < hi) {
                const tmp = results[lo];
                results[lo] = results[hi];
                results[hi] = tmp;
                lo += 1;
                hi -= 1;
            }
        }
        return count;
    }

    /// Count total audit entries.
    pub fn countAuditEntries(self: *Reader) u32 {
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const prefix = keys.prefix_audit;
        @memcpy(lower_buf[0..prefix.len], prefix);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..prefix.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..prefix.len], upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            count += 1;
            if (!iter.next()) break;
        }
        return count;
    }

    // ====================================================================
    // Search
    // ====================================================================

    /// Search jobs by tag key+value within a queue. Scans tq|{key}\x00{value}\x00{queue}\x00 prefix.
    /// Optionally filters by state. Returns up to results.len matching jobs.
    pub fn searchByTag(self: *Reader, tag_key: []const u8, tag_value: []const u8, queue: []const u8, state: ?[]const u8, results: []JobRow) u32 {
        const max_scan = 10_000;
        const state_byte: ?u8 = if (state) |s| stateStringToByte(s) else null;
        var batch = self.store.newBatch();
        defer batch.close();

        var prefix_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const prefix = keys.tagQueuePrefix(&prefix_buf, queue, tag_key, tag_value);
        const upper = keys.prefixEnd(&upper_buf, prefix) orelse return 0;

        var iter = batch.newIter(prefix, upper);
        defer iter.close();

        var count: u32 = 0;
        var scanned: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len or scanned >= max_scan) break;
            scanned += 1;
            const k = iter.key();
            const job_id = keys.jobIdFromTagQueueKey(k) orelse {
                if (!iter.next()) break;
                continue;
            };
            var job_key_buf: keys.KeyBuf = undefined;
            if (batch.get(keys.jobKey(&job_key_buf, job_id))) |job_val| {
                const job = codec.decodeJob(job_val);
                if (state_byte) |sb| {
                    if (@intFromEnum(job.state) != sb) {
                        if (!iter.next()) break;
                        continue;
                    }
                }
                results[count] = jobToRow(&job);
                count += 1;
            }
            if (!iter.next()) break;
        }
        return count;
    }

    /// Brute-force payload search. Scans jp| prefix with substring match, capped.
    pub fn searchPayload(self: *Reader, query: []const u8, results: []JobRow) u32 {
        const max_scan = 10_000;
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        const p = keys.prefix_job_payload;
        @memcpy(lower_buf[0..p.len], p);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..p.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..p.len], upper);
        defer iter.close();

        var count: u32 = 0;
        var scanned: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len or scanned >= max_scan) break;
            scanned += 1;
            const k = iter.key();
            const v = iter.value();

            if (std.mem.indexOf(u8, v, query) != null) {
                // Extract job_id from jp|{job_id}
                const job_id = k[p.len..];
                var job_key_buf: keys.KeyBuf = undefined;
                if (batch.get(keys.jobKey(&job_key_buf, job_id))) |job_val| {
                    const job = codec.decodeJob(job_val);
                    results[count] = jobToRow(&job);
                    count += 1;
                }
            }
            if (!iter.next()) break;
        }
        return count;
    }


    // ====================================================================
    // Internal helpers
    // ====================================================================

    /// Scan a prefix index, look up j|{id} for each, populate results.
    fn scanJobsByIndex(self: *Reader, batch: *kv.WriteBatch, prefix: []const u8, results: []JobRow) u32 {
        _ = self;
        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        @memcpy(lower_buf[0..prefix.len], prefix);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..prefix.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..prefix.len], upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len) break;
            const k = iter.key();
            // Extract job_id from jt|{inv_ts:8BE}{job_id}
            const job_id = keys.jobIdFromTimeKey(k);
            var job_key_buf: keys.KeyBuf = undefined;
            if (batch.get(keys.jobKey(&job_key_buf, job_id))) |job_val| {
                const job = codec.decodeJob(job_val);
                results[count] = jobToRow(&job);
                count += 1;
            }
            if (!iter.next()) break;
        }
        return count;
    }

    /// Scan any prefix that maps to job IDs, look up j|{id} for each.
    fn scanJobsByPrefix(self: *Reader, batch: *kv.WriteBatch, prefix: []const u8, limit: u32, results: []JobRow) u32 {
        _ = self;
        var upper_buf: keys.KeyBuf = undefined;
        const upper = keys.prefixEnd(&upper_buf, prefix) orelse return 0;

        var iter = batch.newIter(prefix, upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= limit) break;
            const k = iter.key();
            // The key contains the job_id after the last structured field.
            // For jqs|: jqs|{queue}\x00{state:1}{inv_ts:8BE}{job_id}
            // For jq|:  jq|{queue}\x00{inv_ts:8BE}{job_id}
            // For js|:  js|{state:1}{inv_ts:8BE}{job_id}
            // We can determine format by the prefix.
            const job_id = extractJobIdFromIndexKey(k) orelse {
                if (!iter.next()) break;
                continue;
            };
            var job_key_buf: keys.KeyBuf = undefined;
            if (batch.get(keys.jobKey(&job_key_buf, job_id))) |job_val| {
                const job = codec.decodeJob(job_val);
                results[count] = jobToRow(&job);
                count += 1;
            }
            if (!iter.next()) break;
        }
        return count;
    }

    fn scanPrefix(
        self: *Reader,
        prefix: []const u8,
        comptime T: type,
        results: []T,
        parseFn: *const fn ([]const u8) T,
    ) u32 {
        var batch = self.store.newBatch();
        defer batch.close();

        var lower_buf: keys.KeyBuf = undefined;
        var upper_buf: keys.KeyBuf = undefined;
        @memcpy(lower_buf[0..prefix.len], prefix);
        const upper = keys.prefixEnd(&upper_buf, lower_buf[0..prefix.len]) orelse return 0;

        var iter = batch.newIter(lower_buf[0..prefix.len], upper);
        defer iter.close();

        var count: u32 = 0;
        if (!iter.first()) return 0;
        while (true) {
            if (count >= results.len) break;
            results[count] = parseFn(iter.value());
            count += 1;
            if (!iter.next()) break;
        }
        return count;
    }
};

// ============================================================================
// Conversion helpers
// ============================================================================

fn extractJobIdFromIndexKey(k: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, k, keys.prefix_job_time)) {
        return keys.jobIdFromTimeKey(k);
    } else if (std.mem.startsWith(u8, k, keys.prefix_job_queue_state)) {
        return keys.jobIdFromQueueStateKey(k);
    } else if (std.mem.startsWith(u8, k, keys.prefix_job_queue)) {
        return keys.jobIdFromQueueKey(k);
    } else if (std.mem.startsWith(u8, k, keys.prefix_job_state)) {
        return keys.jobIdFromStateKey(k);
    }
    return null;
}

fn jobToRow(job: *const types.Job) JobRow {
    var row = JobRow{
        .priority = @intCast(job.priority),
        .attempt = @intCast(job.attempt),
        .max_retries = @intCast(job.max_retries),
        .chain_step = @intCast(job.chain_step),
        .retry_base_delay_ms = @intCast(job.retry_base_delay_ms),
        .retry_max_delay_ms = @intCast(job.retry_max_delay_ms),
    };

    copyField(&row.id, &row.id_len, job.id);
    copyField(&row.queue, &row.queue_len, job.queue);

    const state_str = job.state.toString();
    copyField(&row.state, &row.state_len, state_str);

    if (job.worker_id) |v| copyField(&row.worker_id, &row.worker_id_len, v);
    if (job.hostname) |v| copyField(&row.hostname, &row.hostname_len, v);
    if (job.tags) |v| copyField16(&row.tags, &row.tags_len, v);
    if (job.checkpoint) |v| copyField16(&row.checkpoint, &row.checkpoint_len, v);
    if (job.result) |v| copyField16(&row.result, &row.result_len, v);
    if (job.hold_reason) |v| copyField(&row.hold_reason, &row.hold_reason_len, v);
    if (job.batch_id) |v| copyField(&row.batch_id, &row.batch_id_len, v);
    if (job.unique_key) |v| copyField(&row.unique_key, &row.unique_key_len, v);
    if (job.parent_id) |v| copyField(&row.parent_id, &row.parent_id_len, v);
    if (job.chain_id) |v| copyField(&row.chain_id, &row.chain_id_len, v);
    if (job.group) |v| copyField(&row.group_key, &row.group_key_len, v);
    if (job.progress) |v| copyField16(&row.progress, &row.progress_len, v);

    const backoff_str = job.retry_backoff.toString();
    copyField(&row.retry_backoff, &row.retry_backoff_len, backoff_str);

    formatNs(&row.created_at, &row.created_at_len, job.created_at_ns);
    formatNs(&row.started_at, &row.started_at_len, job.started_at_ns);
    formatNs(&row.completed_at, &row.completed_at_len, job.completed_at_ns);
    formatNs(&row.failed_at, &row.failed_at_len, job.failed_at_ns);
    formatNs(&row.scheduled_at, &row.scheduled_at_len, job.scheduled_at_ns);
    formatNs(&row.lease_expires_at, &row.lease_expires_at_len, job.lease_expires_at_ns);
    formatNs(&row.expire_at, &row.expire_at_len, job.expire_at_ns);

    return row;
}

fn cronToRow(c: *const types.Cron) CronRow {
    var row = CronRow{
        .enabled = c.enabled,
    };
    copyField(&row.id, &row.id_len, c.id);
    copyField(&row.name, &row.name_len, c.name);
    copyField(&row.queue, &row.queue_len, c.queue);
    copyField(&row.schedule, &row.schedule_len, c.schedule);
    return row;
}

fn apiKeyFromValue(val: []const u8) ApiKeyRow {
    // API key values are JSON: {"name":"...","role":"...","enabled":true,"key_hash":"...","created_at_ns":...}
    var row = ApiKeyRow{};
    if (jsonStr(val, "key_hash")) |v| copyField(&row.key_hash, &row.key_hash_len, v);
    if (jsonStr(val, "name")) |v| copyField(&row.name, &row.name_len, v);
    if (jsonStr(val, "role")) |v| copyField(&row.role, &row.role_len, v);
    if (jsonStr(val, "created_at_ns")) |_| {} else if (jsonStr(val, "created_at")) |v| copyField(&row.created_at, &row.created_at_len, v);
    if (jsonInt(val, "created_at_ns")) |ns| formatNs(&row.created_at, &row.created_at_len, ns);
    if (jsonBool(val, "enabled")) |e| row.enabled = e;
    return row;
}

fn webhookFromValue(val: []const u8) WebhookRow {
    // Webhook values are JSON: {"id":"...","url":"...","queue":"*","events":"job.completed,job.failed,job.dead","enabled":true,"created_at_ns":...}
    var row = WebhookRow{};
    if (jsonStr(val, "id")) |v| copyField(&row.id, &row.id_len, v);
    if (jsonStr(val, "url")) |v| copyField16(&row.url, &row.url_len, v);
    if (jsonStr(val, "queue")) |v| copyField(&row.queue_filter, &row.queue_filter_len, v);
    if (jsonStr(val, "events")) |v| copyField(&row.events, &row.events_len, v);
    if (jsonInt(val, "created_at_ns")) |ns| formatNs(&row.created_at, &row.created_at_len, ns);
    if (jsonBool(val, "enabled")) |e| row.enabled = e;
    return row;
}

fn auditEntryFromValue(val: []const u8) AuditEntryRow {
    // Audit values are JSON: {"op":"cancel","target":"queue:default","count":5,"actor":"admin","ts":1234567890}
    var row = AuditEntryRow{};
    if (jsonStr(val, "op")) |v| copyField(&row.op, &row.op_len, v);
    if (jsonStr(val, "target")) |v| copyField16(&row.target, &row.target_len, v);
    if (jsonStr(val, "actor")) |v| copyField(&row.actor, &row.actor_len, v);
    if (jsonInt(val, "count")) |c| row.count = @intCast(c);
    if (jsonInt(val, "ts")) |ts| {
        row.ts = ts;
        formatNs(&row.created_at, &row.created_at_len, ts);
    }
    return row;
}

/// Minimal JSON string extractor: finds "key":"value" and returns value.
fn jsonStr(body: []const u8, key: []const u8) ?[]const u8 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    const val_start = start + search_key.len;
    if (val_start >= body.len) return null;
    const end = std.mem.indexOfScalar(u8, body[val_start..], '"') orelse return null;
    return body[val_start..][0..end];
}

/// Minimal JSON integer extractor: finds "key":12345 and returns value.
fn jsonInt(body: []const u8, key: []const u8) ?u64 {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    var val_start = start + search_key.len;
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;
    if (body[val_start] == '"') return null; // it's a string, not int
    var end = val_start;
    while (end < body.len and body[end] >= '0' and body[end] <= '9') end += 1;
    if (end == val_start) return null;
    return std.fmt.parseInt(u64, body[val_start..end], 10) catch null;
}

/// Minimal JSON boolean extractor: finds "key":true or "key":false.
fn jsonBool(body: []const u8, key: []const u8) ?bool {
    var search_buf: [128]u8 = undefined;
    const search_key = std.fmt.bufPrint(&search_buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, search_key) orelse return null;
    var val_start = start + search_key.len;
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start + 4 <= body.len and std.mem.eql(u8, body[val_start..][0..4], "true")) return true;
    if (val_start + 5 <= body.len and std.mem.eql(u8, body[val_start..][0..5], "false")) return false;
    return null;
}

fn stateStringToByte(state: []const u8) ?u8 {
    if (std.mem.eql(u8, state, "pending")) return @intFromEnum(types.JobState.pending);
    if (std.mem.eql(u8, state, "active")) return @intFromEnum(types.JobState.active);
    if (std.mem.eql(u8, state, "retrying")) return @intFromEnum(types.JobState.retrying);
    if (std.mem.eql(u8, state, "completed")) return @intFromEnum(types.JobState.completed);
    if (std.mem.eql(u8, state, "dead")) return @intFromEnum(types.JobState.dead);
    if (std.mem.eql(u8, state, "cancelled")) return @intFromEnum(types.JobState.cancelled);
    if (std.mem.eql(u8, state, "scheduled")) return @intFromEnum(types.JobState.scheduled);
    if (std.mem.eql(u8, state, "held")) return @intFromEnum(types.JobState.held);
    return null;
}

fn stateCountFromStats(stats: *const QueueStats, state: []const u8) i32 {
    if (std.mem.eql(u8, state, "pending")) return stats.pending;
    if (std.mem.eql(u8, state, "active")) return stats.active;
    if (std.mem.eql(u8, state, "retrying")) return stats.retrying;
    if (std.mem.eql(u8, state, "completed")) return stats.completed;
    if (std.mem.eql(u8, state, "dead")) return stats.dead;
    if (std.mem.eql(u8, state, "scheduled")) return stats.scheduled;
    if (std.mem.eql(u8, state, "held")) return stats.held;
    return 0;
}

fn copyField(dest: anytype, len_ptr: *u8, src: []const u8) void {
    const l: u8 = @intCast(@min(src.len, dest.len));
    @memcpy(dest[0..l], src[0..l]);
    len_ptr.* = l;
}

fn copyField16(dest: anytype, len_ptr: *u16, src: []const u8) void {
    const l: u16 = @intCast(@min(src.len, dest.len));
    @memcpy(dest[0..l], src[0..l]);
    len_ptr.* = l;
}

fn copyField16x(dest: anytype, len_ptr: *u8, src: []const u8) void {
    const l: u8 = @intCast(@min(src.len, dest.len));
    @memcpy(dest[0..l], src[0..l]);
    len_ptr.* = l;
}

/// Format nanosecond timestamp as ISO 8601 string (seconds precision).
/// Writes nothing if ns == 0.
fn formatNs(dest: *[32]u8, len_ptr: *u8, ns: u64) void {
    if (ns == 0) return;
    const secs = ns / 1_000_000_000;
    const epoch = std.time.epoch.EpochSeconds{ .secs = secs };
    const day = epoch.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = epoch.getDaySeconds();

    const written = std.fmt.bufPrint(dest, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        yd.year,
        @as(u32, @intFromEnum(md.month)) + 1,
        @as(u32, md.day_index) + 1,
        ds.getHoursIntoDay(),
        ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    }) catch return;
    len_ptr.* = @intCast(written.len);
}
