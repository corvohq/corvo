//! SQLite read methods — typed queries against the materialized view.
//!
//! Ported from Go internal/sqlite/read_*.go.
//! All methods operate on the mirror SQLite DB (read-only path).

const std = @import("std");
const sqlite = @import("sqlite.zig");
const types = @import("types.zig");

// ============================================================================
// Result types
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
};

pub const QueueRow = struct {
    name: [128]u8 = undefined,
    name_len: u8 = 0,
    paused: bool = false,
    max_concurrency: ?i32 = null,
    rate_limit: ?i32 = null,

    pub fn nameSlice(self: *const QueueRow) []const u8 {
        return self.name[0..self.name_len];
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
    paused: bool = false,

    pub fn nameSlice(self: *const QueueStats) []const u8 {
        return self.name[0..self.name_len];
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

pub const CronRow = struct {
    id: [128]u8 = undefined,
    id_len: u8 = 0,
    name: [128]u8 = undefined,
    name_len: u8 = 0,
    queue: [128]u8 = undefined,
    queue_len: u8 = 0,
    schedule: [64]u8 = undefined,
    schedule_len: u8 = 0,
    timezone: [64]u8 = undefined,
    timezone_len: u8 = 0,
    payload: [4096]u8 = undefined,
    payload_len: u16 = 0,
    unique_key: [128]u8 = undefined,
    unique_key_len: u8 = 0,
    max_retries: i32 = 0,
    enabled: bool = true,
    next_run_at: [32]u8 = undefined,
    next_run_at_len: u8 = 0,
    last_run_at: [32]u8 = undefined,
    last_run_at_len: u8 = 0,
    created_at: [32]u8 = undefined,
    created_at_len: u8 = 0,

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
    pub fn timezoneSlice(self: *const CronRow) []const u8 {
        return self.timezone[0..self.timezone_len];
    }
    pub fn payloadSlice(self: *const CronRow) []const u8 {
        return self.payload[0..self.payload_len];
    }
    pub fn uniqueKeySlice(self: *const CronRow) []const u8 {
        return self.unique_key[0..self.unique_key_len];
    }
    pub fn nextRunAtSlice(self: *const CronRow) []const u8 {
        return self.next_run_at[0..self.next_run_at_len];
    }
    pub fn lastRunAtSlice(self: *const CronRow) []const u8 {
        return self.last_run_at[0..self.last_run_at_len];
    }
    pub fn createdAtSlice(self: *const CronRow) []const u8 {
        return self.created_at[0..self.created_at_len];
    }
};

pub const DueCronRow = struct {
    id: [128]u8 = undefined,
    id_len: u8 = 0,
    schedule: [64]u8 = undefined,
    schedule_len: u8 = 0,
    timezone: [64]u8 = undefined,
    timezone_len: u8 = 0,

    pub fn idSlice(self: *const DueCronRow) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn scheduleSlice(self: *const DueCronRow) []const u8 {
        return self.schedule[0..self.schedule_len];
    }
    pub fn timezoneSlice(self: *const DueCronRow) []const u8 {
        return self.timezone[0..self.timezone_len];
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

// ============================================================================
// Reader
// ============================================================================

pub const Reader = struct {
    db: *sqlite.DB,

    // Full column list for job queries — indices must match readJobRow.
    const job_cols =
        "id, queue, state, priority, attempt, max_retries," ++
        " worker_id, hostname, tags, checkpoint, result," ++
        " hold_reason, error_msg, batch_id, unique_key," ++
        " parent_id, chain_id, chain_step, group_key," ++
        " created_at, started_at, completed_at, failed_at, scheduled_at, lease_expires_at";

    // Full column list for cron queries — indices must match readCronRow.
    const cron_cols =
        "id, name, queue, schedule, timezone, payload, unique_key, max_retries, enabled," ++
        " next_run_at, last_run_at, created_at";

    pub fn init(db: *sqlite.DB) Reader {
        return .{ .db = db };
    }

    // ====================================================================
    // Jobs
    // ====================================================================

    /// Get a single job by ID.
    pub fn getJob(self: *Reader, job_id: []const u8) !?JobRow {
        var stmt = try self.db.prepare(
            "SELECT " ++ job_cols ++ " FROM jobs WHERE id = ?",
        );
        defer stmt.finalize();

        stmt.bindText(1, job_id);
        if (!(try stmt.step())) return null;

        return readJobRow(&stmt);
    }

    /// Count jobs in a given state.
    pub fn countJobsByState(self: *Reader, state: []const u8) !i32 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM jobs WHERE state = ?");
        defer stmt.finalize();

        stmt.bindText(1, state);
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    /// Count jobs in a queue with a given state.
    pub fn countJobsByQueueState(self: *Reader, queue: []const u8, state: []const u8) !i32 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM jobs WHERE queue = ? AND state = ?");
        defer stmt.finalize();

        stmt.bindText(1, queue);
        stmt.bindText(2, state);
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    /// List jobs by state with limit.
    pub fn listJobsByState(self: *Reader, state: []const u8, results: []JobRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT " ++ job_cols ++ " FROM jobs WHERE state = ? ORDER BY created_at DESC LIMIT ?",
        );
        defer stmt.finalize();

        stmt.bindText(1, state);
        stmt.bindInt(2, @intCast(results.len));

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readJobRow(&stmt);
            count += 1;
        }
        return count;
    }

    /// Get errors for a job.
    pub fn getJobErrors(self: *Reader, job_id: []const u8, results: []JobError) !u32 {
        var stmt = try self.db.prepare(
            "SELECT attempt, error, created_at FROM job_errors WHERE job_id = ? ORDER BY attempt",
        );
        defer stmt.finalize();

        stmt.bindText(1, job_id);
        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            var row = JobError{
                .attempt = stmt.columnInt(0),
            };
            if (stmt.columnText(1)) |msg| {
                const len = @min(msg.len, row.error_msg.len);
                @memcpy(row.error_msg[0..len], msg[0..len]);
                row.error_msg_len = @intCast(len);
            }
            if (stmt.columnText(2)) |ts| {
                const len = @min(ts.len, row.created_at.len);
                @memcpy(row.created_at[0..len], ts[0..len]);
                row.created_at_len = @intCast(len);
            }
            results[count] = row;
            count += 1;
        }
        return count;
    }

    // ====================================================================
    // Queues
    // ====================================================================

    /// List all queues.
    pub fn listQueues(self: *Reader, results: []QueueRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT name, paused, max_concurrency, rate_limit FROM queues ORDER BY name",
        );
        defer stmt.finalize();

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            var row = QueueRow{
                .paused = stmt.columnInt(1) != 0,
            };
            if (stmt.columnText(0)) |name| {
                const len = @min(name.len, row.name.len);
                @memcpy(row.name[0..len], name[0..len]);
                row.name_len = @intCast(len);
            }
            if (!stmt.columnIsNull(2)) row.max_concurrency = stmt.columnInt(2);
            if (!stmt.columnIsNull(3)) row.rate_limit = stmt.columnInt(3);
            results[count] = row;
            count += 1;
        }
        return count;
    }

    /// Get queue stats (job counts per state).
    pub fn getQueueStats(self: *Reader, results: []QueueStats) !u32 {
        var stmt = try self.db.prepare(
            \\SELECT q.name, q.paused,
            \\  COALESCE(SUM(CASE WHEN j.state = 'pending' THEN 1 ELSE 0 END), 0),
            \\  COALESCE(SUM(CASE WHEN j.state = 'active' THEN 1 ELSE 0 END), 0),
            \\  COALESCE(SUM(CASE WHEN j.state = 'retrying' THEN 1 ELSE 0 END), 0),
            \\  COALESCE(SUM(CASE WHEN j.state = 'scheduled' THEN 1 ELSE 0 END), 0),
            \\  COALESCE(SUM(CASE WHEN j.state = 'completed' THEN 1 ELSE 0 END), 0),
            \\  COALESCE(SUM(CASE WHEN j.state = 'dead' THEN 1 ELSE 0 END), 0)
            \\FROM queues q LEFT JOIN jobs j ON j.queue = q.name
            \\GROUP BY q.name ORDER BY q.name
        );
        defer stmt.finalize();

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            var row = QueueStats{
                .paused = stmt.columnInt(1) != 0,
                .pending = stmt.columnInt(2),
                .active = stmt.columnInt(3),
                .retrying = stmt.columnInt(4),
                .scheduled = stmt.columnInt(5),
                .completed = stmt.columnInt(6),
                .dead = stmt.columnInt(7),
            };
            if (stmt.columnText(0)) |name| {
                const len = @min(name.len, row.name.len);
                @memcpy(row.name[0..len], name[0..len]);
                row.name_len = @intCast(len);
            }
            results[count] = row;
            count += 1;
        }
        return count;
    }

    // ====================================================================
    // Crons
    // ====================================================================

    /// Get a single cron by ID.
    pub fn getCron(self: *Reader, cron_id: []const u8) !?CronRow {
        var stmt = try self.db.prepare(
            "SELECT " ++ cron_cols ++ " FROM crons WHERE id = ?",
        );
        defer stmt.finalize();

        stmt.bindText(1, cron_id);
        if (!(try stmt.step())) return null;

        return readCronRow(&stmt);
    }

    /// List all crons.
    pub fn listCrons(self: *Reader, results: []CronRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT " ++ cron_cols ++ " FROM crons ORDER BY name",
        );
        defer stmt.finalize();

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readCronRow(&stmt);
            count += 1;
        }
        return count;
    }

    /// Find crons that are enabled and due before the given timestamp.
    pub fn findDueCrons(self: *Reader, before: []const u8, results: []DueCronRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT id, schedule, timezone FROM crons WHERE enabled = 1 AND next_run_at IS NOT NULL AND next_run_at <= ?",
        );
        defer stmt.finalize();

        stmt.bindText(1, before);
        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            var row = DueCronRow{};
            if (stmt.columnText(0)) |id| {
                const il: u8 = @intCast(@min(id.len, row.id.len));
                @memcpy(row.id[0..il], id[0..il]);
                row.id_len = il;
            }
            if (stmt.columnText(1)) |sched| {
                const sl: u8 = @intCast(@min(sched.len, row.schedule.len));
                @memcpy(row.schedule[0..sl], sched[0..sl]);
                row.schedule_len = sl;
            }
            if (stmt.columnText(2)) |tz| {
                const tl: u8 = @intCast(@min(tz.len, row.timezone.len));
                @memcpy(row.timezone[0..tl], tz[0..tl]);
                row.timezone_len = tl;
            }
            results[count] = row;
            count += 1;
        }
        return count;
    }

    // ====================================================================
    // Workers
    // ====================================================================

    /// Get all crons.
    pub fn getCrons(self: *Reader, results: []CronRow) !u32 {
        return self.listCrons(results);
    }

    /// Get all workers.
    pub fn getWorkers(self: *Reader, results: []WorkerRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT id, hostname, queues, last_heartbeat, started_at FROM workers ORDER BY id",
        );
        defer stmt.finalize();

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            var row = WorkerRow{};
            if (stmt.columnText(0)) |v| {
                const len = @min(v.len, row.id.len);
                @memcpy(row.id[0..len], v[0..len]);
                row.id_len = @intCast(len);
            }
            if (stmt.columnText(1)) |v| {
                const len = @min(v.len, row.hostname.len);
                @memcpy(row.hostname[0..len], v[0..len]);
                row.hostname_len = @intCast(len);
            }
            if (stmt.columnText(2)) |v| {
                const len: u16 = @intCast(@min(v.len, row.queues.len));
                @memcpy(row.queues[0..len], v[0..len]);
                row.queues_len = len;
            }
            if (stmt.columnText(3)) |v| {
                const len = @min(v.len, row.last_heartbeat.len);
                @memcpy(row.last_heartbeat[0..len], v[0..len]);
                row.last_heartbeat_len = @intCast(len);
            }
            if (stmt.columnText(4)) |v| {
                const len = @min(v.len, row.started_at.len);
                @memcpy(row.started_at[0..len], v[0..len]);
                row.started_at_len = @intCast(len);
            }
            results[count] = row;
            count += 1;
        }
        return count;
    }

    /// Get jobs (limited).
    pub fn getJobs(self: *Reader, results: []JobRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT " ++ job_cols ++ " FROM jobs ORDER BY created_at DESC LIMIT ?",
        );
        defer stmt.finalize();

        stmt.bindInt(1, @intCast(results.len));
        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readJobRow(&stmt);
            count += 1;
        }
        return count;
    }

    /// Count total workers.
    pub fn countWorkers(self: *Reader) !i32 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM workers");
        defer stmt.finalize();
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    /// Count workers with heartbeat more recent than cutoff.
    pub fn countActiveWorkers(self: *Reader, cutoff: []const u8) !i32 {
        var stmt = try self.db.prepare(
            "SELECT COUNT(*) FROM workers WHERE last_heartbeat IS NOT NULL AND last_heartbeat >= ?",
        );
        defer stmt.finalize();
        stmt.bindText(1, cutoff);
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    // ====================================================================
    // FTS5 Search
    // ====================================================================

    /// Search jobs using FTS5 full-text search on payload and tags.
    pub fn searchJobs(self: *Reader, query: []const u8, results: []JobRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT j.id, j.queue, j.state, j.priority, j.attempt, j.max_retries," ++
                " j.worker_id, j.hostname, j.tags, j.checkpoint, j.result," ++
                " j.hold_reason, j.error_msg, j.batch_id, j.unique_key," ++
                " j.parent_id, j.chain_id, j.chain_step, j.group_key," ++
                " j.created_at, j.started_at, j.completed_at, j.failed_at, j.scheduled_at, j.lease_expires_at" ++
                " FROM jobs_fts f JOIN jobs j ON j.id = f.job_id" ++
                " WHERE jobs_fts MATCH ? ORDER BY rank LIMIT ?",
        );
        defer stmt.finalize();

        stmt.bindText(1, query);
        stmt.bindInt(2, @intCast(results.len));

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readJobRow(&stmt);
            count += 1;
        }
        return count;
    }

    /// LIKE fallback for full-text search when FTS5 fails.
    /// Searches payload using LIKE '%query%'.
    pub fn searchJobsLike(self: *Reader, query: []const u8, results: []JobRow) !u32 {
        var like_buf: [256]u8 = undefined;
        const like_pattern = std.fmt.bufPrint(&like_buf, "%{s}%", .{query}) catch return 0;

        var stmt = try self.db.prepare(
            "SELECT j.id, j.queue, j.state, j.priority, j.attempt, j.max_retries," ++
                " j.worker_id, j.hostname, j.tags, j.checkpoint, j.result," ++
                " j.hold_reason, j.error_msg, j.batch_id, j.unique_key," ++
                " j.parent_id, j.chain_id, j.chain_step, j.group_key," ++
                " j.created_at, j.started_at, j.completed_at, j.failed_at, j.scheduled_at, j.lease_expires_at" ++
                " FROM jobs j JOIN job_payloads jp ON jp.job_id = j.id" ++
                " WHERE jp.payload LIKE ?" ++
                " ORDER BY j.created_at DESC LIMIT ?",
        );
        defer stmt.finalize();

        stmt.bindText(1, like_pattern);
        stmt.bindInt(2, @intCast(results.len));

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readJobRow(&stmt);
            count += 1;
        }
        return count;
    }

    // ====================================================================
    // Job Iterations
    // ====================================================================

    // ====================================================================
    // Budgets
    // ====================================================================

    /// List all budgets.
    pub fn listBudgets(self: *Reader, results: []BudgetRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT scope, target, daily_usd, per_job_usd, on_exceed, created_at" ++
                " FROM budgets ORDER BY scope, target",
        );
        defer stmt.finalize();

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            var row = BudgetRow{
                .daily_usd = stmt.columnDouble(2),
                .per_job_usd = stmt.columnDouble(3),
            };
            if (stmt.columnText(0)) |v| {
                const len = @min(v.len, row.scope.len);
                @memcpy(row.scope[0..len], v[0..len]);
                row.scope_len = @intCast(len);
            }
            if (stmt.columnText(1)) |v| {
                const len = @min(v.len, row.target.len);
                @memcpy(row.target[0..len], v[0..len]);
                row.target_len = @intCast(len);
            }
            if (stmt.columnText(4)) |v| {
                const len = @min(v.len, row.on_exceed.len);
                @memcpy(row.on_exceed[0..len], v[0..len]);
                row.on_exceed_len = @intCast(len);
            }
            if (stmt.columnText(5)) |v| {
                const len = @min(v.len, row.created_at.len);
                @memcpy(row.created_at[0..len], v[0..len]);
                row.created_at_len = @intCast(len);
            }
            results[count] = row;
            count += 1;
        }
        return count;
    }

    /// Get a budget by scope + target.
    pub fn getBudget(self: *Reader, scope: []const u8, target: []const u8) !?BudgetRow {
        var stmt = try self.db.prepare(
            "SELECT scope, target, daily_usd, per_job_usd, on_exceed, created_at" ++
                " FROM budgets WHERE scope = ? AND target = ?",
        );
        defer stmt.finalize();
        stmt.bindText(1, scope);
        stmt.bindText(2, target);
        if (!(try stmt.step())) return null;
        return readBudgetRow(&stmt);
    }

    /// Fetch budgets applicable to a queue (queue-scoped + global).
    pub fn fetchQueueBudgets(self: *Reader, queue: []const u8, results: []BudgetRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT scope, target, daily_usd, per_job_usd, on_exceed, created_at" ++
                " FROM budgets WHERE (scope = 'queue' AND target = ?) OR (scope = 'global' AND target = '*')",
        );
        defer stmt.finalize();
        stmt.bindText(1, queue);
        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readBudgetRow(&stmt);
            count += 1;
        }
        return count;
    }

    /// Find oldest pending job in a queue.
    pub fn findPendingJobInQueue(self: *Reader, queue: []const u8) !?[128]u8 {
        var stmt = try self.db.prepare(
            "SELECT id FROM jobs WHERE queue = ? AND state = 'pending' ORDER BY created_at ASC LIMIT 1",
        );
        defer stmt.finalize();
        stmt.bindText(1, queue);
        if (!(try stmt.step())) return null;
        if (stmt.columnText(0)) |id| {
            var buf: [128]u8 = undefined;
            const len = @min(id.len, buf.len);
            @memcpy(buf[0..len], id[0..len]);
            return buf;
        }
        return null;
    }

    /// Check if any budgets are configured.
    pub fn hasBudgets(self: *Reader) !bool {
        var stmt = try self.db.prepare("SELECT 1 FROM budgets LIMIT 1");
        defer stmt.finalize();
        return try stmt.step();
    }

    pub const JobQueueAndTags = struct {
        queue: [128]u8 = undefined,
        queue_len: u8 = 0,
        tags: [512]u8 = undefined,
        tags_len: u16 = 0,

        pub fn queueSlice(self: *const JobQueueAndTags) []const u8 {
            return self.queue[0..self.queue_len];
        }
        pub fn tagsSlice(self: *const JobQueueAndTags) []const u8 {
            return self.tags[0..self.tags_len];
        }
    };

    /// Get queue and tags for a job by ID.
    pub fn getJobQueueAndTags(self: *Reader, job_id: []const u8) !?JobQueueAndTags {
        var stmt = try self.db.prepare("SELECT queue, tags FROM jobs WHERE id = ?");
        defer stmt.finalize();
        stmt.bindText(1, job_id);
        if (!(try stmt.step())) return null;
        var result = JobQueueAndTags{};
        if (stmt.columnText(0)) |q| {
            const ql = @min(q.len, result.queue.len);
            @memcpy(result.queue[0..ql], q[0..ql]);
            result.queue_len = @intCast(ql);
        }
        if (stmt.columnText(1)) |t| {
            const tl: u16 = @intCast(@min(t.len, result.tags.len));
            @memcpy(result.tags[0..tl], t[0..tl]);
            result.tags_len = tl;
        }
        return result;
    }

    /// List budgets that have a per_job_usd limit set.
    pub fn listPerJobBudgets(self: *Reader, results: []BudgetRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT scope, target, daily_usd, per_job_usd, on_exceed, created_at" ++
                " FROM budgets WHERE per_job_usd IS NOT NULL",
        );
        defer stmt.finalize();
        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readBudgetRow(&stmt);
            count += 1;
        }
        return count;
    }

    // ====================================================================
    // Job Query (filtered listing with pagination)
    // ====================================================================

    /// Query jobs by queue and state with pagination.
    pub fn queryJobsByQueueState(
        self: *Reader,
        queue: ?[]const u8,
        state: ?[]const u8,
        limit: u32,
        offset: u32,
        results: []JobRow,
    ) !u32 {
        if (queue != null and state != null) {
            var stmt = try self.db.prepare(
                "SELECT " ++ job_cols ++ " FROM jobs WHERE queue = ? AND state = ?" ++
                    " ORDER BY created_at DESC LIMIT ? OFFSET ?",
            );
            defer stmt.finalize();
            stmt.bindText(1, queue.?);
            stmt.bindText(2, state.?);
            stmt.bindInt(3, @intCast(limit));
            stmt.bindInt(4, @intCast(offset));
            return readJobRows(&stmt, results);
        } else if (queue != null) {
            var stmt = try self.db.prepare(
                "SELECT " ++ job_cols ++ " FROM jobs WHERE queue = ?" ++
                    " ORDER BY created_at DESC LIMIT ? OFFSET ?",
            );
            defer stmt.finalize();
            stmt.bindText(1, queue.?);
            stmt.bindInt(2, @intCast(limit));
            stmt.bindInt(3, @intCast(offset));
            return readJobRows(&stmt, results);
        } else if (state != null) {
            var stmt = try self.db.prepare(
                "SELECT " ++ job_cols ++ " FROM jobs WHERE state = ?" ++
                    " ORDER BY created_at DESC LIMIT ? OFFSET ?",
            );
            defer stmt.finalize();
            stmt.bindText(1, state.?);
            stmt.bindInt(2, @intCast(limit));
            stmt.bindInt(3, @intCast(offset));
            return readJobRows(&stmt, results);
        } else {
            var stmt = try self.db.prepare(
                "SELECT " ++ job_cols ++ " FROM jobs ORDER BY created_at DESC LIMIT ? OFFSET ?",
            );
            defer stmt.finalize();
            stmt.bindInt(1, @intCast(limit));
            stmt.bindInt(2, @intCast(offset));
            return readJobRows(&stmt, results);
        }
    }

    // ====================================================================
    // API Keys
    // ====================================================================

    /// List all API keys.
    pub fn listApiKeys(self: *Reader, results: []ApiKeyRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT key_hash, name, role, enabled, expires_at, created_at" ++
                " FROM api_keys ORDER BY created_at",
        );
        defer stmt.finalize();

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readApiKeyRow(&stmt);
            count += 1;
        }
        return count;
    }

    /// Get a single API key by hash.
    pub fn getApiKeyByHash(self: *Reader, key_hash: []const u8) !?ApiKeyRow {
        var stmt = try self.db.prepare(
            "SELECT key_hash, name, role, enabled, expires_at, created_at" ++
                " FROM api_keys WHERE key_hash = ?",
        );
        defer stmt.finalize();

        stmt.bindText(1, key_hash);
        if (!(try stmt.step())) return null;

        return readApiKeyRow(&stmt);
    }

    /// Count enabled API keys.
    pub fn countEnabledApiKeys(self: *Reader) !i32 {
        var stmt = try self.db.prepare("SELECT COUNT(*) FROM api_keys WHERE enabled = 1");
        defer stmt.finalize();
        _ = try stmt.step();
        return stmt.columnInt(0);
    }

    // ====================================================================
    // Approval Policies
    // ====================================================================

    pub fn listApprovalPolicies(self: *Reader, results: []ApprovalPolicyRow) !u32 {
        var stmt = try self.db.prepare(
            "SELECT id, name, mode, enabled, queue, tag_key, tag_value, created_at" ++
                " FROM approval_policies ORDER BY created_at DESC, id DESC",
        );
        defer stmt.finalize();

        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            var row = ApprovalPolicyRow{};
            row.enabled = stmt.columnInt(3) != 0;
            inline for (.{
                .{ 0, &row.id, &row.id_len },
                .{ 1, &row.name, &row.name_len },
                .{ 2, &row.mode, &row.mode_len },
                .{ 4, &row.queue, &row.queue_len },
                .{ 5, &row.tag_key, &row.tag_key_len },
                .{ 6, &row.tag_value, &row.tag_value_len },
                .{ 7, &row.created_at, &row.created_at_len },
            }) |f| {
                if (stmt.columnText(f[0])) |v| {
                    const len = @min(v.len, f[1].len);
                    @memcpy(f[1][0..len], v[0..len]);
                    f[2].* = @intCast(len);
                }
            }
            results[count] = row;
            count += 1;
        }
        return count;
    }

    // ====================================================================
    // Helpers
    // ====================================================================

    /// Read cron row: id(0), name(1), queue(2), schedule(3), timezone(4),
    /// payload(5), unique_key(6), max_retries(7), enabled(8),
    /// next_run_at(9), last_run_at(10), created_at(11).
    fn readCronRow(stmt: *sqlite.Stmt) CronRow {
        var row = CronRow{
            .max_retries = stmt.columnInt(7),
            .enabled = stmt.columnInt(8) != 0,
        };
        if (stmt.columnText(0)) |v| {
            const len = @min(v.len, row.id.len);
            @memcpy(row.id[0..len], v[0..len]);
            row.id_len = @intCast(len);
        }
        if (stmt.columnText(1)) |v| {
            const len = @min(v.len, row.name.len);
            @memcpy(row.name[0..len], v[0..len]);
            row.name_len = @intCast(len);
        }
        if (stmt.columnText(2)) |v| {
            const len = @min(v.len, row.queue.len);
            @memcpy(row.queue[0..len], v[0..len]);
            row.queue_len = @intCast(len);
        }
        if (stmt.columnText(3)) |v| {
            const len = @min(v.len, row.schedule.len);
            @memcpy(row.schedule[0..len], v[0..len]);
            row.schedule_len = @intCast(len);
        }
        if (stmt.columnText(4)) |v| {
            const len = @min(v.len, row.timezone.len);
            @memcpy(row.timezone[0..len], v[0..len]);
            row.timezone_len = @intCast(len);
        }
        if (stmt.columnText(5)) |v| {
            const len: u16 = @intCast(@min(v.len, row.payload.len));
            @memcpy(row.payload[0..len], v[0..len]);
            row.payload_len = len;
        }
        if (stmt.columnText(6)) |v| {
            const len = @min(v.len, row.unique_key.len);
            @memcpy(row.unique_key[0..len], v[0..len]);
            row.unique_key_len = @intCast(len);
        }
        if (stmt.columnText(9)) |v| {
            const len = @min(v.len, row.next_run_at.len);
            @memcpy(row.next_run_at[0..len], v[0..len]);
            row.next_run_at_len = @intCast(len);
        }
        if (stmt.columnText(10)) |v| {
            const len = @min(v.len, row.last_run_at.len);
            @memcpy(row.last_run_at[0..len], v[0..len]);
            row.last_run_at_len = @intCast(len);
        }
        if (stmt.columnText(11)) |v| {
            const len = @min(v.len, row.created_at.len);
            @memcpy(row.created_at[0..len], v[0..len]);
            row.created_at_len = @intCast(len);
        }
        return row;
    }

    fn readApiKeyRow(stmt: *sqlite.Stmt) ApiKeyRow {
        var row = ApiKeyRow{
            .enabled = stmt.columnInt(3) != 0,
        };
        if (stmt.columnText(0)) |v| {
            const len = @min(v.len, row.key_hash.len);
            @memcpy(row.key_hash[0..len], v[0..len]);
            row.key_hash_len = @intCast(len);
        }
        if (stmt.columnText(1)) |v| {
            const len = @min(v.len, row.name.len);
            @memcpy(row.name[0..len], v[0..len]);
            row.name_len = @intCast(len);
        }
        if (stmt.columnText(2)) |v| {
            const len = @min(v.len, row.role.len);
            @memcpy(row.role[0..len], v[0..len]);
            row.role_len = @intCast(len);
        }
        if (stmt.columnText(4)) |v| {
            const len = @min(v.len, row.expires_at.len);
            @memcpy(row.expires_at[0..len], v[0..len]);
            row.expires_at_len = @intCast(len);
        }
        if (stmt.columnText(5)) |v| {
            const len = @min(v.len, row.created_at.len);
            @memcpy(row.created_at[0..len], v[0..len]);
            row.created_at_len = @intCast(len);
        }
        return row;
    }

    fn readBudgetRow(stmt: *sqlite.Stmt) BudgetRow {
        var row = BudgetRow{
            .daily_usd = stmt.columnDouble(2),
            .per_job_usd = stmt.columnDouble(3),
        };
        if (stmt.columnText(0)) |v| {
            const len = @min(v.len, row.scope.len);
            @memcpy(row.scope[0..len], v[0..len]);
            row.scope_len = @intCast(len);
        }
        if (stmt.columnText(1)) |v| {
            const len = @min(v.len, row.target.len);
            @memcpy(row.target[0..len], v[0..len]);
            row.target_len = @intCast(len);
        }
        if (stmt.columnText(4)) |v| {
            const len = @min(v.len, row.on_exceed.len);
            @memcpy(row.on_exceed[0..len], v[0..len]);
            row.on_exceed_len = @intCast(len);
        }
        if (stmt.columnText(5)) |v| {
            const len = @min(v.len, row.created_at.len);
            @memcpy(row.created_at[0..len], v[0..len]);
            row.created_at_len = @intCast(len);
        }
        return row;
    }

    fn readJobRows(stmt: *sqlite.Stmt, results: []JobRow) !u32 {
        var count: u32 = 0;
        while (try stmt.step()) {
            if (count >= results.len) break;
            results[count] = readJobRow(stmt);
            count += 1;
        }
        return count;
    }

    /// Read job row — column indices match job_cols:
    /// 0:id, 1:queue, 2:state, 3:priority, 4:attempt, 5:max_retries,
    /// 6:worker_id, 7:hostname, 8:tags, 9:checkpoint, 10:result,
    /// 11:hold_reason, 12:error_msg, 13:batch_id, 14:unique_key,
    /// 15:parent_id, 16:chain_id, 17:chain_step, 18:group_key,
    /// 19:created_at, 20:started_at, 21:completed_at, 22:failed_at,
    /// 23:scheduled_at, 24:lease_expires_at.
    fn readJobRow(stmt: *sqlite.Stmt) JobRow {
        var row = JobRow{
            .priority = stmt.columnInt(3),
            .attempt = stmt.columnInt(4),
            .max_retries = stmt.columnInt(5),
            .chain_step = stmt.columnInt(17),
        };
        // Text columns — small fixed buffers (u8 len).
        inline for (.{
            .{ @as(c_int, 0), &row.id, &row.id_len },
            .{ @as(c_int, 1), &row.queue, &row.queue_len },
            .{ @as(c_int, 2), &row.state, &row.state_len },
            .{ @as(c_int, 6), &row.worker_id, &row.worker_id_len },
            .{ @as(c_int, 7), &row.hostname, &row.hostname_len },
            .{ @as(c_int, 11), &row.hold_reason, &row.hold_reason_len },
            .{ @as(c_int, 13), &row.batch_id, &row.batch_id_len },
            .{ @as(c_int, 14), &row.unique_key, &row.unique_key_len },
            .{ @as(c_int, 15), &row.parent_id, &row.parent_id_len },
            .{ @as(c_int, 16), &row.chain_id, &row.chain_id_len },
            .{ @as(c_int, 18), &row.group_key, &row.group_key_len },
            .{ @as(c_int, 19), &row.created_at, &row.created_at_len },
            .{ @as(c_int, 20), &row.started_at, &row.started_at_len },
            .{ @as(c_int, 21), &row.completed_at, &row.completed_at_len },
            .{ @as(c_int, 22), &row.failed_at, &row.failed_at_len },
            .{ @as(c_int, 23), &row.scheduled_at, &row.scheduled_at_len },
            .{ @as(c_int, 24), &row.lease_expires_at, &row.lease_expires_at_len },
        }) |col| {
            if (stmt.columnText(col[0])) |v| {
                const len = @min(v.len, col[1].len);
                @memcpy(col[1][0..len], v[0..len]);
                col[2].* = @intCast(len);
            }
        }
        // Text columns — larger buffers (u16 len).
        inline for (.{
            .{ @as(c_int, 8), &row.tags, &row.tags_len },
            .{ @as(c_int, 9), &row.checkpoint, &row.checkpoint_len },
            .{ @as(c_int, 10), &row.result, &row.result_len },
            .{ @as(c_int, 12), &row.error_msg, &row.error_msg_len },
        }) |col| {
            if (stmt.columnText(col[0])) |v| {
                const len: u16 = @intCast(@min(v.len, col[1].len));
                @memcpy(col[1][0..len], v[0..len]);
                col[2].* = len;
            }
        }
        return row;
    }
};

// ============================================================================
// Tests
// ============================================================================

test "reader getJob" {
    const schema_mod = @import("schema.zig");

    var db = try sqlite.DB.open(":memory:", .{ .in_memory = true });
    defer db.close();
    try schema_mod.createSchema(&db);

    try db.exec("INSERT INTO jobs (id, queue, state, priority, max_retries, created_at) VALUES ('j1', 'q1', 'pending', 2, 3, '1000000000')");

    var reader = Reader.init(&db);
    const job = try reader.getJob("j1");
    try std.testing.expect(job != null);
    try std.testing.expectEqualStrings("j1", job.?.idSlice());
    try std.testing.expectEqualStrings("q1", job.?.queueSlice());
    try std.testing.expectEqualStrings("pending", job.?.stateSlice());
}

test "reader countJobsByState" {
    const schema_mod = @import("schema.zig");

    var db = try sqlite.DB.open(":memory:", .{ .in_memory = true });
    defer db.close();
    try schema_mod.createSchema(&db);

    try db.exec("INSERT INTO jobs (id, queue, state) VALUES ('j1', 'q1', 'pending')");
    try db.exec("INSERT INTO jobs (id, queue, state) VALUES ('j2', 'q1', 'pending')");
    try db.exec("INSERT INTO jobs (id, queue, state) VALUES ('j3', 'q1', 'active')");

    var reader = Reader.init(&db);
    try std.testing.expectEqual(@as(i32, 2), try reader.countJobsByState("pending"));
    try std.testing.expectEqual(@as(i32, 1), try reader.countJobsByState("active"));
    try std.testing.expectEqual(@as(i32, 0), try reader.countJobsByState("dead"));
}

test "reader getQueueStats" {
    const schema_mod = @import("schema.zig");

    var db = try sqlite.DB.open(":memory:", .{ .in_memory = true });
    defer db.close();
    try schema_mod.createSchema(&db);

    try db.exec("INSERT INTO queues (name) VALUES ('q1')");
    try db.exec("INSERT INTO jobs (id, queue, state) VALUES ('j1', 'q1', 'pending')");
    try db.exec("INSERT INTO jobs (id, queue, state) VALUES ('j2', 'q1', 'active')");
    try db.exec("INSERT INTO jobs (id, queue, state) VALUES ('j3', 'q1', 'pending')");

    var reader = Reader.init(&db);
    var stats_buf: [8]QueueStats = undefined;
    const count = try reader.getQueueStats(&stats_buf);
    try std.testing.expectEqual(@as(u32, 1), count);
    try std.testing.expectEqualStrings("q1", stats_buf[0].nameSlice());
    try std.testing.expectEqual(@as(i32, 2), stats_buf[0].pending);
    try std.testing.expectEqual(@as(i32, 1), stats_buf[0].active);
}

// ============================================================================
// Approval Policies
// ============================================================================

pub const ApprovalPolicyRow = struct {
    id: [64]u8 = [_]u8{0} ** 64,
    id_len: u8 = 0,
    name: [128]u8 = [_]u8{0} ** 128,
    name_len: u8 = 0,
    mode: [8]u8 = [_]u8{0} ** 8,
    mode_len: u8 = 0,
    enabled: bool = true,
    queue: [64]u8 = [_]u8{0} ** 64,
    queue_len: u8 = 0,
    tag_key: [64]u8 = [_]u8{0} ** 64,
    tag_key_len: u8 = 0,
    tag_value: [128]u8 = [_]u8{0} ** 128,
    tag_value_len: u8 = 0,
    created_at: [32]u8 = [_]u8{0} ** 32,
    created_at_len: u8 = 0,

    pub fn idSlice(self: *const ApprovalPolicyRow) []const u8 {
        return self.id[0..self.id_len];
    }
    pub fn nameSlice(self: *const ApprovalPolicyRow) []const u8 {
        return self.name[0..self.name_len];
    }
    pub fn modeSlice(self: *const ApprovalPolicyRow) []const u8 {
        return self.mode[0..self.mode_len];
    }
    pub fn queueSlice(self: *const ApprovalPolicyRow) []const u8 {
        return self.queue[0..self.queue_len];
    }
    pub fn tagKeySlice(self: *const ApprovalPolicyRow) []const u8 {
        return self.tag_key[0..self.tag_key_len];
    }
    pub fn tagValueSlice(self: *const ApprovalPolicyRow) []const u8 {
        return self.tag_value[0..self.tag_value_len];
    }
    pub fn createdAtSlice(self: *const ApprovalPolicyRow) []const u8 {
        return self.created_at[0..self.created_at_len];
    }

    /// Check if this policy matches a job with the given queue and tags JSON.
    pub fn matches(self: *const ApprovalPolicyRow, job_queue: []const u8, tags_json: []const u8) bool {
        if (!self.enabled) return false;

        const has_queue = self.queue_len > 0;
        const has_tag = self.tag_key_len > 0;

        if (!has_queue and !has_tag) return false;

        const queue_match = if (has_queue) std.mem.eql(u8, self.queueSlice(), job_queue) else false;
        const tag_match = if (has_tag) matchTag(self.tagKeySlice(), self.tagValueSlice(), tags_json) else false;

        const is_all = std.mem.eql(u8, self.modeSlice(), "all");
        if (is_all) {
            // ALL mode: every specified condition must match.
            if (has_queue and !queue_match) return false;
            if (has_tag and !tag_match) return false;
            return true;
        } else {
            // ANY mode: at least one condition must match.
            return (has_queue and queue_match) or (has_tag and tag_match);
        }
    }
};

/// Simple tag matching: search for "key":"value" in the JSON string.
fn matchTag(key: []const u8, value: []const u8, tags_json: []const u8) bool {
    if (tags_json.len < 5) return false; // At minimum: {"k":"v"}
    // Build search pattern: "key":"value"
    var pattern: [256]u8 = undefined;
    const pat = std.fmt.bufPrint(&pattern, "\"{s}\":\"{s}\"", .{ key, value }) catch return false;
    return std.mem.indexOf(u8, tags_json, pat) != null;
}
