package server

import (
	"fmt"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/user/jobbie/internal/search"
	"github.com/user/jobbie/internal/store"
)

const bulkAsyncChunkSize = 500

type bulkTaskStatus string

const (
	bulkTaskQueued    bulkTaskStatus = "queued"
	bulkTaskRunning   bulkTaskStatus = "running"
	bulkTaskCompleted bulkTaskStatus = "completed"
	bulkTaskFailed    bulkTaskStatus = "failed"
)

type bulkTaskEvent struct {
	Type        string `json:"type"`
	TaskID      string `json:"task_id"`
	Status      string `json:"status"`
	Affected    int    `json:"affected,omitempty"`
	Total       int    `json:"total,omitempty"`
	Processed   int    `json:"processed,omitempty"`
	Percent     int    `json:"percent,omitempty"`
	Error       string `json:"error,omitempty"`
	CreatedAtNs int64  `json:"created_at_ns"`
}

type bulkTask struct {
	ID         string         `json:"id"`
	Status     bulkTaskStatus `json:"status"`
	Action     string         `json:"action"`
	Total      int            `json:"total"`
	Processed  int            `json:"processed"`
	Affected   int            `json:"affected"`
	Errors     int            `json:"errors"`
	Error      string         `json:"error,omitempty"`
	CreatedAt  time.Time      `json:"created_at"`
	UpdatedAt  time.Time      `json:"updated_at"`
	FinishedAt *time.Time     `json:"finished_at,omitempty"`
}

type asyncBulkManager struct {
	mu       sync.RWMutex
	tasks    map[string]*bulkTask
	events   map[string]chan bulkTaskEvent
	store    *store.Store
	stopOnce sync.Once
}

var bulkTaskSeq atomic.Uint64

func newAsyncBulkManager(s *store.Store) *asyncBulkManager {
	return &asyncBulkManager{
		tasks:  make(map[string]*bulkTask),
		events: make(map[string]chan bulkTaskEvent),
		store:  s,
	}
}

func (m *asyncBulkManager) start(req store.BulkRequest) (*bulkTask, error) {
	if req.Action == "" {
		return nil, fmt.Errorf("action is required")
	}
	id := newBulkTaskID()
	now := time.Now().UTC()
	task := &bulkTask{
		ID:        id,
		Status:    bulkTaskQueued,
		Action:    req.Action,
		CreatedAt: now,
		UpdatedAt: now,
	}
	m.mu.Lock()
	m.tasks[id] = task
	m.events[id] = make(chan bulkTaskEvent, 1024)
	m.mu.Unlock()

	go m.run(task, req)
	return copyBulkTask(task), nil
}

func (m *asyncBulkManager) get(id string) (*bulkTask, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	task, ok := m.tasks[id]
	if !ok {
		return nil, false
	}
	return copyBulkTask(task), true
}

func (m *asyncBulkManager) eventsFor(id string) (<-chan bulkTaskEvent, bool) {
	m.mu.RLock()
	defer m.mu.RUnlock()
	ch, ok := m.events[id]
	return ch, ok
}

func (m *asyncBulkManager) run(task *bulkTask, req store.BulkRequest) {
	m.update(task.ID, func(t *bulkTask) {
		t.Status = bulkTaskRunning
	})
	m.publish(task.ID, bulkTaskEvent{
		Type:        "bulk.async.started",
		TaskID:      task.ID,
		Status:      string(bulkTaskRunning),
		CreatedAtNs: time.Now().UnixNano(),
	})

	resolvedIDs := req.JobIDs
	if len(resolvedIDs) == 0 && req.Filter != nil {
		ids, err := m.resolveFilterToIDs(*req.Filter)
		if err != nil {
			m.fail(task.ID, err)
			return
		}
		resolvedIDs = ids
	}

	m.update(task.ID, func(t *bulkTask) {
		t.Total = len(resolvedIDs)
	})

	if len(resolvedIDs) == 0 {
		m.complete(task.ID)
		return
	}

	processed := 0
	for i := 0; i < len(resolvedIDs); i += bulkAsyncChunkSize {
		end := i + bulkAsyncChunkSize
		if end > len(resolvedIDs) {
			end = len(resolvedIDs)
		}
		chunk := resolvedIDs[i:end]
		out, err := m.store.BulkAction(store.BulkRequest{
			JobIDs:      chunk,
			Action:      req.Action,
			MoveToQueue: req.MoveToQueue,
			Priority:    req.Priority,
		})
		if err != nil {
			m.fail(task.ID, err)
			return
		}
		processed += len(chunk)
		m.update(task.ID, func(t *bulkTask) {
			t.Processed = processed
			t.Affected += out.Affected
			t.Errors += out.Errors
		})
		t, _ := m.get(task.ID)
		percent := 0
		if t.Total > 0 {
			percent = int(float64(t.Processed) * 100 / float64(t.Total))
		}
		m.publish(task.ID, bulkTaskEvent{
			Type:        "bulk.async.progress",
			TaskID:      task.ID,
			Status:      string(bulkTaskRunning),
			Total:       t.Total,
			Processed:   t.Processed,
			Affected:    t.Affected,
			Percent:     percent,
			CreatedAtNs: time.Now().UnixNano(),
		})
	}

	m.complete(task.ID)
}

func (m *asyncBulkManager) update(id string, fn func(t *bulkTask)) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if t, ok := m.tasks[id]; ok {
		fn(t)
		t.UpdatedAt = time.Now().UTC()
	}
}

func (m *asyncBulkManager) complete(id string) {
	now := time.Now().UTC()
	m.update(id, func(t *bulkTask) {
		t.Status = bulkTaskCompleted
		t.FinishedAt = &now
	})
	t, _ := m.get(id)
	m.publish(id, bulkTaskEvent{
		Type:        "bulk.async.completed",
		TaskID:      id,
		Status:      string(bulkTaskCompleted),
		Total:       t.Total,
		Processed:   t.Processed,
		Affected:    t.Affected,
		CreatedAtNs: time.Now().UnixNano(),
	})
	m.closeEvents(id)
}

func (m *asyncBulkManager) fail(id string, err error) {
	now := time.Now().UTC()
	m.update(id, func(t *bulkTask) {
		t.Status = bulkTaskFailed
		t.Error = err.Error()
		t.FinishedAt = &now
	})
	t, _ := m.get(id)
	m.publish(id, bulkTaskEvent{
		Type:        "bulk.async.failed",
		TaskID:      id,
		Status:      string(bulkTaskFailed),
		Error:       t.Error,
		Total:       t.Total,
		Processed:   t.Processed,
		Affected:    t.Affected,
		CreatedAtNs: time.Now().UnixNano(),
	})
	m.closeEvents(id)
}

func (m *asyncBulkManager) publish(id string, ev bulkTaskEvent) {
	m.mu.RLock()
	ch, ok := m.events[id]
	m.mu.RUnlock()
	if !ok {
		return
	}
	select {
	case ch <- ev:
	default:
		// drop event under pressure; status endpoint remains source of truth
	}
}

func (m *asyncBulkManager) closeEvents(id string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	if ch, ok := m.events[id]; ok {
		close(ch)
		delete(m.events, id)
	}
}

func copyBulkTask(t *bulkTask) *bulkTask {
	if t == nil {
		return nil
	}
	cp := *t
	if t.FinishedAt != nil {
		ft := *t.FinishedAt
		cp.FinishedAt = &ft
	}
	return &cp
}

func newBulkTaskID() string {
	ns := time.Now().UTC().UnixNano()
	seq := bulkTaskSeq.Add(1)
	return "bulk_" + strconv.FormatInt(ns, 36) + "_" + strconv.FormatUint(seq, 36)
}

func (m *asyncBulkManager) countFilter(filter search.Filter) (int, error) {
	filter.Limit = 0
	_, countQuery, _, args, err := search.BuildQuery(filter)
	if err != nil {
		return 0, err
	}
	var n int
	if err := m.store.ReadDB().QueryRow(countQuery, args...).Scan(&n); err != nil {
		return 0, err
	}
	return n, nil
}

func (m *asyncBulkManager) resolveFilterToIDs(filter search.Filter) ([]string, error) {
	filter.Limit = 0
	query, _, args, _, err := search.BuildQuery(filter)
	if err != nil {
		return nil, err
	}
	idx := strings.Index(query, "FROM jobs j")
	if idx == -1 {
		return nil, fmt.Errorf("unexpected search query format")
	}
	idQuery := "SELECT j.id " + query[idx:]
	rows, err := m.store.ReadDB().Query(idQuery, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var ids []string
	for rows.Next() {
		var id string
		if err := rows.Scan(&id); err != nil {
			return nil, err
		}
		ids = append(ids, id)
	}
	if err := rows.Err(); err != nil {
		return nil, err
	}
	return ids, nil
}
