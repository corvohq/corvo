# Corvo Code Conventions & Cookbook

## Module Path
```
github.com/corvohq/corvo
```

## Import Ordering
```go
import (
    // 1. stdlib
    "context"
    "encoding/json"
    "fmt"
    "net/http"
    "time"

    // 2. third-party
    "github.com/go-chi/chi/v5"
    "github.com/cockroachdb/pebble"
    "github.com/spf13/cobra"

    // 3. internal
    "github.com/corvohq/corvo/internal/kv"
    "github.com/corvohq/corvo/internal/store"
)
```

## Naming Conventions

| Layer | Pattern | Example |
|-------|---------|---------|
| Op constant | `Op<VerbNoun>` | `OpCancelJob`, `OpMoveJob` |
| Op struct | `<VerbNoun>Op` | `CancelJobOp`, `MoveJobOp` |
| FSM JSON handler | `apply<OpName>(data json.RawMessage)` | `applyCancelJob` |
| FSM typed handler | `apply<OpName>Op(op store.<Name>Op)` | `applyCancelJobOp` |
| Store method | `<VerbNoun>(...)` | `CancelJob`, `MoveJob` |
| HTTP handler | `handle<VerbNoun>(w, r)` | `handleCancelJob` |
| CLI command var | `<verb>Cmd` | `cancelCmd`, `moveCmd` |

### File Naming
| Pattern | Examples |
|---------|---------|
| `handlers_<domain>.go` | `handlers_manage.go`, `handlers_budget.go` |
| `cmd_<domain>.go` | `cmd_jobs.go`, `cmd_queues.go` |
| `fsm_<topic>.go` | `fsm_ops.go`, `fsm_enterprise.go` |
| `<domain>.go` in store | `jobs.go`, `queues.go`, `enqueue.go` |

## Adding a New FSM Op (9 files)

### 1. Op Type Constant — `internal/store/ops.go`
```go
const (
    OpExisting OpType = 47
    OpYourOp   OpType = 48  // next sequential integer, never reuse
)
```

### 2. Op Struct — `internal/store/ops.go`
```go
type YourOp struct {
    JobID string `json:"job_id"`
    NowNs uint64 `json:"now_ns"`  // always pre-compute timestamps outside FSM
}
```
All timestamp fields use `NowNs uint64` (nanoseconds since epoch). No `time.Now()` inside FSM handlers.

### 3. DecodedRaftOp Field — `internal/store/raft_proto_codec.go`
```go
type DecodedRaftOp struct {
    Type    OpType
    // ...existing...
    YourOp  *YourOp
}
```
Also add encode/decode cases in the same file.

### 4. FSM Handler — `internal/raft/fsm_ops.go`
```go
func (f *FSM) applyYourOp(data json.RawMessage) *store.OpResult {
    var op store.YourOp
    if err := json.Unmarshal(data, &op); err != nil {
        return &store.OpResult{Err: err}
    }
    return f.applyYourOpOp(op)
}

func (f *FSM) applyYourOpOp(op store.YourOp) *store.OpResult {
    // 1. Read from Pebble: f.pebble.Get(kv.JobKey(op.JobID))
    // 2. Create batch: batch := f.pebble.NewBatch(); defer batch.Close()
    // 3. Mutate KV state (delete/write index keys, update job doc)
    // 4. Commit: batch.Commit(f.writeOpts)
    // 5. SQLite mirror: f.syncSQLite(func(db sqlExecer) error { ... })
    // 6. Return: &store.OpResult{Data: result}
}
```

### 5. FSM Dispatch — `internal/raft/fsm.go`
Add a case in **both** switch statements:

**`applyByType` (JSON/legacy path):**
```go
case store.OpYourOp:
    return f.applyYourOp(data)
```

**`applyDecoded` (binary/proto fast path):**
```go
case store.OpYourOp:
    if op.YourOp != nil {
        return f.applyYourOpOp(*op.YourOp)
    }
    return &store.OpResult{Err: fmt.Errorf("your op missing payload")}
```

### 6. Store Method — `internal/store/<domain>.go`
```go
func (s *Store) YourOp(id string) (string, error) {
    op := YourOp{
        JobID: id,
        NowNs: uint64(time.Now().UnixNano()),
    }
    res := s.applyOp(OpYourOp, op)
    if res.Err != nil {
        return "", res.Err
    }
    return res.Data.(string), nil
}
```

### 7. HTTP Handler — `internal/server/handlers_<domain>.go`
```go
func (s *Server) handleYourOp(w http.ResponseWriter, r *http.Request) {
    id := chi.URLParam(r, "id")
    result, err := s.store.YourOp(id)
    if err != nil {
        writeStoreError(w, err, http.StatusBadRequest, "YOUR_ERROR")
        return
    }
    writeJSON(w, http.StatusOK, map[string]string{"status": result})
}
```

### 8. Route Registration — `internal/server/server.go`
In `buildRouter()`, inside the `requireLeader` group for write ops:
```go
r.Post("/jobs/{id}/your-op", s.handleYourOp)
```
Read ops go outside `requireLeader`.

### 9. CLI Command — `cmd/corvo/cmd_<domain>.go`
```go
var yourCmd = &cobra.Command{
    Use:   "your-op <job-id>",
    Short: "Description",
    Args:  cobra.ExactArgs(1),
    RunE: func(cmd *cobra.Command, args []string) error {
        data, status, err := apiRequest("POST", "/api/v1/jobs/"+args[0]+"/your-op", nil)
        if err != nil { return err }
        exitOnError(data, status)
        var result map[string]string
        json.Unmarshal(data, &result)
        fmt.Printf("Job %s: %s\n", args[0], result["status"])
        return nil
    },
}

func init() {
    addClientFlags(yourCmd)  // adds --server, --api-key, --output-json
    rootCmd.AddCommand(yourCmd)
}
```

## Adding a New HTTP Endpoint (no FSM op)

Route registration in `internal/server/server.go` `buildRouter()`:
```go
r.Route("/api/v1", func(r chi.Router) {
    r.Use(s.authMiddleware)
    r.Get("/your/read", s.handleYourRead)           // any node
    r.Group(func(r chi.Router) {
        r.Use(s.requireLeader)
        r.Post("/your/write", s.handleYourWrite)    // leader only
    })
})
```

Response helpers:
- `writeJSON(w, status, v)` — JSON response
- `writeError(w, status, msg, code)` — error response
- `writeStoreError(w, err, fallbackStatus, fallbackCode)` — auto-handles OVERLOADED/BUDGET_EXCEEDED
- `decodeJSON(r, &body)` — parse request body

## Adding a New RPC Method

1. Add to `proto/corvo/v1/worker.proto`
2. Run `buf generate`
3. Implement on `*Server` in `internal/rpcconnect/server.go`:
```go
func (s *Server) YourMethod(
    ctx context.Context,
    req *connect.Request[corvov1.YourRequest],
) (*connect.Response[corvov1.YourResponse], error) {
    result, err := s.store.SomeMethod(req.Msg.GetField())
    if err != nil {
        return nil, mapStoreError(err)
    }
    return connect.NewResponse(&corvov1.YourResponse{Result: result}), nil
}
```

## Error Handling

### Error Flow
```
FSM: return &store.OpResult{Err: fmt.Errorf("job not found")}
  → Store: return res.Err
    → Handler: writeStoreError(w, err, 400, "YOUR_ERROR")
      → Client: HTTP 400 {"error":"job not found","code":"YOUR_ERROR"}
```

### Special Error Types (`internal/store/errors.go`)
```go
store.NewOverloadedError(msg)              // → HTTP 429, code "OVERLOADED"
store.NewOverloadedErrorRetry(msg, retryMs) // → HTTP 429 + Retry-After header
store.NewBudgetExceededError(msg)          // → HTTP 429, code "BUDGET_EXCEEDED"
```

Always use `writeStoreError` first — it auto-handles these two types. Only fall back to `writeError` for domain-specific errors.

### Error Codes
| Code | HTTP | When |
|------|------|------|
| `OVERLOADED` | 429 | Apply queue full, stream saturated |
| `BUDGET_EXCEEDED` | 429 | LLM cost budget hit |
| `VALIDATION_ERROR` | 400 | Bad input |
| `PARSE_ERROR` | 400 | Invalid JSON |
| `NOT_FOUND` | 404 | Job/resource missing |
| `CANCEL_ERROR` / `RETRY_ERROR` / etc. | 400 | State machine violation |
| `LEADER_UNAVAILABLE` | 503 | No leader elected |
| `INTERNAL_ERROR` | 500 | Storage failure |

## FSM Handler Pattern

Every FSM handler follows this structure:
```go
func (f *FSM) applyFooOp(op store.FooOp) *store.OpResult {
    // 1. Load existing state from Pebble
    val, closer, err := f.pebble.Get(kv.JobKey(op.JobID))
    if err != nil { return &store.OpResult{Err: ...} }
    var job store.Job
    decodeJobDoc(val, &job)
    closer.Close()

    // 2. Validate state transition
    if job.State != store.StateActive {
        return &store.OpResult{Err: fmt.Errorf("invalid state")}
    }

    // 3. Build Pebble batch
    batch := f.pebble.NewBatch()
    defer batch.Close()

    // 4. Delete old index keys, write new ones
    batch.Delete(kv.ActiveKey(job.Queue, op.JobID), pebble.NoSync)
    job.State = store.StateCancelled
    encoded := encodeJobDoc(job)
    batch.Set(kv.JobKey(op.JobID), encoded, f.writeOpts)

    // 5. Commit
    if err := batch.Commit(f.writeOpts); err != nil {
        return &store.OpResult{Err: err}
    }

    // 6. Mirror to SQLite
    f.syncSQLite(func(db sqlExecer) error {
        _, err := db.Exec("UPDATE jobs SET state=?, ... WHERE id=?", job.State, op.JobID)
        return err
    })

    // 7. Update in-memory caches
    f.decrActive(job.Queue)

    return &store.OpResult{Data: job.State}
}
```

## CLI Helpers (`cmd/corvo/cli.go`)
- `apiRequest(method, path, body)` — HTTP request with auth, returns `([]byte, int, error)`
- `exitOnError(data, status)` — exit 1 on HTTP >= 400
- `printJSON(data)` — pretty-print
- `resolveAPIKey()` — checks `--api-key` flag then `CORVO_API_KEY` env
- `addClientFlags(cmd)` — adds `--server`, `--api-key`, `--output-json`
