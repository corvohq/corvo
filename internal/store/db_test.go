package store

import (
	"os"
	"path/filepath"
	"testing"
)

func TestOpen(t *testing.T) {
	dir := t.TempDir()

	db, err := Open(dir)
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	// Verify the database file was created
	if _, err := os.Stat(filepath.Join(dir, "jobbie.db")); err != nil {
		t.Fatalf("database file not created: %v", err)
	}

	// Verify WAL mode is active
	var journalMode string
	err = db.Read.QueryRow("PRAGMA journal_mode").Scan(&journalMode)
	if err != nil {
		t.Fatalf("query journal_mode: %v", err)
	}
	if journalMode != "wal" {
		t.Errorf("journal_mode = %q, want %q", journalMode, "wal")
	}

	// Verify foreign keys are enabled
	var fk int
	err = db.Read.QueryRow("PRAGMA foreign_keys").Scan(&fk)
	if err != nil {
		t.Fatalf("query foreign_keys: %v", err)
	}
	if fk != 1 {
		t.Errorf("foreign_keys = %d, want 1", fk)
	}

	// Verify synchronous = NORMAL (1)
	var sync int
	err = db.Read.QueryRow("PRAGMA synchronous").Scan(&sync)
	if err != nil {
		t.Fatalf("query synchronous: %v", err)
	}
	if sync != 1 {
		t.Errorf("synchronous = %d, want 1 (NORMAL)", sync)
	}
}

func TestMigrationCreatesAllTables(t *testing.T) {
	dir := t.TempDir()

	db, err := Open(dir)
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	expectedTables := []string{
		"jobs", "job_errors", "unique_locks", "batches",
		"queues", "rate_limit_window", "schedules",
		"workers", "events", "queue_stats", "schema_migrations", "job_usage", "budgets", "job_iterations",
		"job_scores", "providers", "provider_usage_window",
	}

	for _, table := range expectedTables {
		var name string
		err := db.Read.QueryRow(
			"SELECT name FROM sqlite_master WHERE type='table' AND name=?", table,
		).Scan(&name)
		if err != nil {
			t.Errorf("table %q not found: %v", table, err)
		}
	}
}

func TestMigrationIsIdempotent(t *testing.T) {
	dir := t.TempDir()

	// Open twice — second time should not fail
	db1, err := Open(dir)
	if err != nil {
		t.Fatalf("first Open() error: %v", err)
	}
	db1.Close()

	db2, err := Open(dir)
	if err != nil {
		t.Fatalf("second Open() error: %v", err)
	}
	defer db2.Close()

	// Verify migration version is still latest
	var version int
	err = db2.Read.QueryRow("SELECT MAX(version) FROM schema_migrations").Scan(&version)
	if err != nil {
		t.Fatalf("query migration version: %v", err)
	}
	if version != 7 {
		t.Errorf("migration version = %d, want 7", version)
	}
}

func TestWriteConnMaxOne(t *testing.T) {
	dir := t.TempDir()

	db, err := Open(dir)
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	stats := db.Write.Stats()
	if stats.MaxOpenConnections != 1 {
		t.Errorf("write MaxOpenConnections = %d, want 1", stats.MaxOpenConnections)
	}
}

func TestMigrationCreatesIndexes(t *testing.T) {
	dir := t.TempDir()

	db, err := Open(dir)
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	expectedIndexes := []string{
		"idx_jobs_queue_state_priority",
		"idx_jobs_state",
		"idx_jobs_scheduled",
		"idx_jobs_lease",
		"idx_jobs_unique",
		"idx_jobs_batch",
		"idx_jobs_expire",
		"idx_jobs_created",
		"idx_job_errors_job",
		"idx_rate_limit",
		"idx_events_created",
		"idx_job_usage_job",
		"idx_job_usage_provider",
		"idx_job_usage_model",
		"idx_job_usage_queue",
		"idx_budgets_scope",
		"idx_budgets_target",
		"idx_job_iterations_job",
		"idx_jobs_parent",
		"idx_jobs_chain",
		"idx_jobs_provider_error",
		"idx_job_scores_job",
		"idx_job_scores_dimension",
		"idx_provider_usage",
		"idx_jobs_routing_target",
	}

	for _, idx := range expectedIndexes {
		var name string
		err := db.Read.QueryRow(
			"SELECT name FROM sqlite_master WHERE type='index' AND name=?", idx,
		).Scan(&name)
		if err != nil {
			t.Errorf("index %q not found: %v", idx, err)
		}
	}
}

func TestCanInsertAndQueryJob(t *testing.T) {
	dir := t.TempDir()

	db, err := Open(dir)
	if err != nil {
		t.Fatalf("Open() error: %v", err)
	}
	defer db.Close()

	_, err = db.Write.Exec(`INSERT INTO jobs (id, queue, payload) VALUES (?, ?, ?)`,
		"job_test1", "test.queue", `{"hello":"world"}`)
	if err != nil {
		t.Fatalf("insert job: %v", err)
	}

	var id, queue, state, payload string
	var priority int
	err = db.Read.QueryRow("SELECT id, queue, state, payload, priority FROM jobs WHERE id = ?", "job_test1").
		Scan(&id, &queue, &state, &payload, &priority)
	if err != nil {
		t.Fatalf("query job: %v", err)
	}

	if id != "job_test1" {
		t.Errorf("id = %q, want %q", id, "job_test1")
	}
	if queue != "test.queue" {
		t.Errorf("queue = %q, want %q", queue, "test.queue")
	}
	if state != "pending" {
		t.Errorf("state = %q, want %q", state, "pending")
	}
	if payload != `{"hello":"world"}` {
		t.Errorf("payload = %q, want %q", payload, `{"hello":"world"}`)
	}
	if priority != 2 {
		t.Errorf("priority = %d, want 2", priority)
	}
}
