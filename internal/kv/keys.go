package kv

import "bytes"

// Key prefixes. Each prefix ends with '|' as a separator.
const (
	PrefixJob         = "j|"   // j|{job_id}
	PrefixJobError    = "je|"  // je|{job_id}\x00{attempt:4BE}
	PrefixPending     = "p|"   // p|{queue}\x00{priority:1B}{created_ns:8BE}{job_id}
	PrefixActive      = "a|"   // a|{queue}\x00{job_id}
	PrefixScheduled   = "s|"   // s|{queue}\x00{scheduled_ns:8BE}{job_id}
	PrefixRetrying    = "r|"   // r|{queue}\x00{retry_ns:8BE}{job_id}
	PrefixQueueConfig = "qc|"  // qc|{queue}
	PrefixQueueName   = "qn|"  // qn|{queue}
	PrefixUnique      = "u|"   // u|{queue}\x00{unique_key}
	PrefixRateLimit   = "l|"   // l|{queue}\x00{fetched_ns:8BE}{random:8BE}
	PrefixBatch       = "b|"   // b|{batch_id}
	PrefixWorker      = "w|"   // w|{worker_id}
	PrefixSchedule    = "sc|"  // sc|{schedule_id}
	PrefixQueueAppend = "qa|"  // qa|{queue}\x00{created_ns:8BE}{job_id}
	PrefixQueueCursor = "qac|" // qac|{queue} => last consumed queue-append key
	PrefixEventLog    = "ev|"  // ev|{seq:8BE}
	KeyEventCursor    = "evc|" // evc|last_seq
	PrefixBudget      = "bg|"  // bg|{scope}\x00{target}
)

const sep = '\x00'

// JobKey returns the Pebble key for a job: j|{job_id}
func JobKey(jobID string) []byte {
	return append([]byte(PrefixJob), jobID...)
}

// JobErrorKey returns the Pebble key for a job error: je|{job_id}\x00{attempt:4BE}
func JobErrorKey(jobID string, attempt uint32) []byte {
	k := append([]byte(PrefixJobError), jobID...)
	k = append(k, sep)
	return PutUint32BE(k, attempt)
}

// JobErrorPrefix returns the scan prefix for all errors of a job: je|{job_id}\x00
func JobErrorPrefix(jobID string) []byte {
	k := append([]byte(PrefixJobError), jobID...)
	return append(k, sep)
}

// PendingKey returns the Pebble key for a pending job sorted set entry.
// Sort order: priority ASC, created_ns ASC, then job_id for uniqueness.
// p|{queue}\x00{priority:1B}{created_ns:8BE}{job_id}
func PendingKey(queue string, priority uint8, createdNs uint64, jobID string) []byte {
	k := append([]byte(PrefixPending), queue...)
	k = append(k, sep)
	k = PutUint8(k, priority)
	k = PutUint64BE(k, createdNs)
	return append(k, jobID...)
}

// PendingPrefix returns the scan prefix for all pending jobs in a queue: p|{queue}\x00
func PendingPrefix(queue string) []byte {
	k := append([]byte(PrefixPending), queue...)
	return append(k, sep)
}

// ActiveKey returns the Pebble key for an active job: a|{queue}\x00{job_id}
// Value stores lease_expires_ns as 8-byte big-endian.
func ActiveKey(queue, jobID string) []byte {
	k := append([]byte(PrefixActive), queue...)
	k = append(k, sep)
	return append(k, jobID...)
}

// ActivePrefix returns the scan prefix for all active jobs in a queue: a|{queue}\x00
func ActivePrefix(queue string) []byte {
	k := append([]byte(PrefixActive), queue...)
	return append(k, sep)
}

// ScheduledKey returns the Pebble key for a scheduled job: s|{queue}\x00{scheduled_ns:8BE}{job_id}
func ScheduledKey(queue string, scheduledNs uint64, jobID string) []byte {
	k := append([]byte(PrefixScheduled), queue...)
	k = append(k, sep)
	k = PutUint64BE(k, scheduledNs)
	return append(k, jobID...)
}

// ScheduledScanPrefix returns the scan prefix for scheduled jobs: s|{queue}\x00
func ScheduledScanPrefix(queue string) []byte {
	k := append([]byte(PrefixScheduled), queue...)
	return append(k, sep)
}

// RetryingKey returns the Pebble key for a retrying job: r|{queue}\x00{retry_ns:8BE}{job_id}
func RetryingKey(queue string, retryNs uint64, jobID string) []byte {
	k := append([]byte(PrefixRetrying), queue...)
	k = append(k, sep)
	k = PutUint64BE(k, retryNs)
	return append(k, jobID...)
}

// RetryingScanPrefix returns the scan prefix for retrying jobs: r|{queue}\x00
func RetryingScanPrefix(queue string) []byte {
	k := append([]byte(PrefixRetrying), queue...)
	return append(k, sep)
}

// QueueConfigKey returns the Pebble key for queue config: qc|{queue}
func QueueConfigKey(queue string) []byte {
	return append([]byte(PrefixQueueConfig), queue...)
}

// QueueNameKey returns the Pebble key for queue name registry: qn|{queue}
func QueueNameKey(queue string) []byte {
	return append([]byte(PrefixQueueName), queue...)
}

// UniqueKey returns the Pebble key for a unique lock: u|{queue}\x00{unique_key}
// Value stores: {job_id}|{expires_ns:8BE}
func UniqueKey(queue, uniqueKey string) []byte {
	k := append([]byte(PrefixUnique), queue...)
	k = append(k, sep)
	return append(k, uniqueKey...)
}

// UniquePrefix returns the scan prefix for unique locks in a queue: u|{queue}\x00
func UniquePrefix(queue string) []byte {
	k := append([]byte(PrefixUnique), queue...)
	return append(k, sep)
}

// EncodeUniqueValue encodes the unique lock value: {job_id}|{expires_ns:8BE}
func EncodeUniqueValue(jobID string, expiresNs uint64) []byte {
	v := append([]byte(jobID), '|')
	return PutUint64BE(v, expiresNs)
}

// DecodeUniqueValue decodes the unique lock value into jobID and expiresNs.
func DecodeUniqueValue(val []byte) (jobID string, expiresNs uint64) {
	// Find the last '|' (job IDs don't contain '|')
	for i := len(val) - 9; i >= 0; i-- {
		if val[i] == '|' {
			jobID = string(val[:i])
			expiresNs = GetUint64BE(val[i+1:])
			return
		}
	}
	return string(val), 0
}

// RateLimitKey returns the Pebble key for a rate limit entry:
// l|{queue}\x00{fetched_ns:8BE}{random:8BE}
func RateLimitKey(queue string, fetchedNs, random uint64) []byte {
	k := append([]byte(PrefixRateLimit), queue...)
	k = append(k, sep)
	k = PutUint64BE(k, fetchedNs)
	return PutUint64BE(k, random)
}

// RateLimitPrefix returns the scan prefix for rate limit entries: l|{queue}\x00
func RateLimitPrefix(queue string) []byte {
	k := append([]byte(PrefixRateLimit), queue...)
	return append(k, sep)
}

// RateLimitWindowStart returns the key at which to start scanning for rate limits
// from windowStartNs onwards: l|{queue}\x00{windowStartNs:8BE}
func RateLimitWindowStart(queue string, windowStartNs uint64) []byte {
	k := append([]byte(PrefixRateLimit), queue...)
	k = append(k, sep)
	return PutUint64BE(k, windowStartNs)
}

// BatchKey returns the Pebble key for a batch: b|{batch_id}
func BatchKey(batchID string) []byte {
	return append([]byte(PrefixBatch), batchID...)
}

// WorkerKey returns the Pebble key for a worker: w|{worker_id}
func WorkerKey(workerID string) []byte {
	return append([]byte(PrefixWorker), workerID...)
}

// ScheduleKey returns the Pebble key for a cron schedule: sc|{schedule_id}
func ScheduleKey(scheduleID string) []byte {
	return append([]byte(PrefixSchedule), scheduleID...)
}

// QueueAppendKey returns the append-log key for a queue:
// qa|{queue}\x00{created_ns:8BE}{job_id}
func QueueAppendKey(queue string, createdNs uint64, jobID string) []byte {
	k := append([]byte(PrefixQueueAppend), queue...)
	k = append(k, sep)
	k = PutUint64BE(k, createdNs)
	return append(k, jobID...)
}

// QueueAppendPrefix returns the append-log scan prefix for a queue: qa|{queue}\x00
func QueueAppendPrefix(queue string) []byte {
	k := append([]byte(PrefixQueueAppend), queue...)
	return append(k, sep)
}

// QueueCursorKey returns the cursor key for queue append consumption: qac|{queue}
func QueueCursorKey(queue string) []byte {
	return append([]byte(PrefixQueueCursor), queue...)
}

// EventLogKey returns the Pebble key for an append-only event: ev|{seq:8BE}
func EventLogKey(seq uint64) []byte {
	k := []byte(PrefixEventLog)
	return PutUint64BE(k, seq)
}

// EventLogPrefix returns the scan prefix for all event log entries.
func EventLogPrefix() []byte {
	return []byte(PrefixEventLog)
}

// EventCursorKey returns the Pebble key for the current event cursor.
func EventCursorKey() []byte {
	return []byte(KeyEventCursor)
}

// EventSeqFromKey extracts sequence number from event-log key.
func EventSeqFromKey(k []byte) (uint64, bool) {
	if !bytes.HasPrefix(k, []byte(PrefixEventLog)) {
		return 0, false
	}
	if len(k) != len(PrefixEventLog)+8 {
		return 0, false
	}
	return GetUint64BE(k[len(PrefixEventLog):]), true
}

// BudgetKey returns the Pebble key for a budget config: bg|{scope}\x00{target}
func BudgetKey(scope, target string) []byte {
	k := append([]byte(PrefixBudget), scope...)
	k = append(k, sep)
	return append(k, target...)
}

// BudgetPrefix returns scan prefix for budgets: bg|
func BudgetPrefix() []byte {
	return []byte(PrefixBudget)
}
