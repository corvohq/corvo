//! Simulation configuration — all parameters for a deterministic run.

/// All simulation parameters. All randomness is derived from seed.
pub const Config = struct {
    seed: u64 = 0, // PRNG seed; 0 means random
    ticks: u32 = 5000, // number of simulation ticks
    clients: u32 = 5, // number of simulated workers
    queues: u32 = 3, // number of queues
    tick_duration_ns: i64 = 200_000_000, // 200ms in nanoseconds

    // --- Action probability knobs (0.0-1.0) ---

    // Core lifecycle
    fail_rate: f64 = 0.1, // prob client fails a job instead of acking
    scheduled_job_rate: f64 = 0.1, // fraction of enqueues that are future-scheduled
    priority_rate: f64 = 0.1, // fraction of enqueues with non-normal priority

    // Unique jobs
    unique_rate: f64 = 0.15, // fraction of enqueues with a unique_key

    // Batch operations
    batch_rate: f64 = 0.08, // prob of creating a batch per tick
    batch_enqueue_rate: f64 = 0.2, // fraction of enqueues assigned to open batch

    // Bulk actions (applied to completed/dead/active jobs)
    bulk_rate: f64 = 0.05, // prob of bulk action per tick

    // Maintenance
    maintenance_rate: f64 = 0.08, // prob of running maintenance per tick

    // Queue ops (pause/resume)
    queue_op_rate: f64 = 0.03, // prob of queue op per tick

    // Heartbeat
    heartbeat_rate: f64 = 0.1, // prob of heartbeat for active jobs

    // Stale acks (lease expiry testing)
    stale_rate: f64 = 0.03, // prob of "forgetting" a job instead of acking (lets lease expire)

    // Chain jobs
    chain_rate: f64 = 0.08, // fraction of enqueues that are chain jobs

    // Cron operations
    cron_rate: f64 = 0.03, // prob of cron operation per tick

    // Batch lifecycle (create + seal)
    batch_create_rate: f64 = 0.04, // prob of batch create per tick

    // Heartbeat checkpoint/progress
    checkpoint_rate: f64 = 0.3, // fraction of heartbeats that include checkpoint/progress

    // Time jumps
    time_jump_prob: f64 = 0.02, // prob of a large time jump per tick
    time_jump_max_ns: i64 = 120_000_000_000, // 120s max jump

    // Invariant check interval (every N ticks).
    check_interval: u32 = 10,
};
