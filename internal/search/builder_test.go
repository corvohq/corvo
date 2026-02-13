package search

import (
	"strings"
	"testing"
	"time"
)

func TestBuildQueryNoFilters(t *testing.T) {
	query, _, args, _, err := BuildQuery(Filter{})
	if err != nil {
		t.Fatalf("BuildQuery: %v", err)
	}
	if strings.Contains(query, "WHERE") {
		t.Error("query should not have WHERE clause with no filters")
	}
	// args should only have limit and offset
	if len(args) != 2 {
		t.Errorf("args count = %d, want 2 (limit, offset)", len(args))
	}
}

func TestBuildQueryWithQueue(t *testing.T) {
	query, _, args, _, _ := BuildQuery(Filter{Queue: "test.queue"})
	if !strings.Contains(query, "j.queue = ?") {
		t.Error("query should filter on queue")
	}
	if args[0] != "test.queue" {
		t.Errorf("first arg = %v, want test.queue", args[0])
	}
}

func TestBuildQueryWithState(t *testing.T) {
	query, _, _, _, _ := BuildQuery(Filter{State: []string{"pending", "dead"}})
	if !strings.Contains(query, "j.state IN (?, ?)") {
		t.Error("query should filter on state IN")
	}
}

func TestBuildQueryWithTags(t *testing.T) {
	query, _, _, _, _ := BuildQuery(Filter{Tags: map[string]string{"tenant": "acme"}})
	if !strings.Contains(query, "json_extract(j.tags, '$.tenant') = ?") {
		t.Error("query should filter on tags via json_extract")
	}
}

func TestBuildQueryWithPayloadContains(t *testing.T) {
	query, _, _, _, _ := BuildQuery(Filter{PayloadContains: "user@example.com"})
	if !strings.Contains(query, "j.payload LIKE") {
		t.Error("query should filter on payload LIKE")
	}
}

func TestBuildQueryWithPayloadJQEquality(t *testing.T) {
	query, _, args, _, err := BuildQuery(Filter{PayloadJQ: `.template == "welcome"`})
	if err != nil {
		t.Fatalf("BuildQuery: %v", err)
	}
	if !strings.Contains(query, "json_extract(j.payload") {
		t.Error("query should include json_extract payload_jq clause")
	}
	if len(args) < 4 {
		t.Fatalf("args len = %d, want >= 4", len(args))
	}
	if args[0] != "$.template" {
		t.Fatalf("arg[0] = %v, want $.template", args[0])
	}
	if args[1] != "welcome" {
		t.Fatalf("arg[1] = %v, want welcome", args[1])
	}
}

func TestBuildQueryWithPayloadJQContains(t *testing.T) {
	query, _, args, _, err := BuildQuery(Filter{PayloadJQ: `.tags | contains("vip")`})
	if err != nil {
		t.Fatalf("BuildQuery: %v", err)
	}
	if !strings.Contains(query, "json_each") {
		t.Error("query should include json_each for contains")
	}
	if args[0] != "$.tags" || args[1] != "vip" {
		t.Fatalf("unexpected args: %#v", args[:2])
	}
}

func TestBuildQueryWithPayloadJQInvalid(t *testing.T) {
	_, _, _, _, err := BuildQuery(Filter{PayloadJQ: `.template ~~ "x"`})
	if err == nil {
		t.Fatal("expected error for invalid payload_jq")
	}
}

func TestBuildQueryWithTimeRange(t *testing.T) {
	now := time.Now()
	query, _, _, _, _ := BuildQuery(Filter{CreatedAfter: &now, CreatedBefore: &now})
	if !strings.Contains(query, "j.created_at >") {
		t.Error("query should have created_at > filter")
	}
	if !strings.Contains(query, "j.created_at <") {
		t.Error("query should have created_at < filter")
	}
}

func TestBuildQueryWithErrorFilters(t *testing.T) {
	hasErrors := true
	query, _, _, _, _ := BuildQuery(Filter{HasErrors: &hasErrors, ErrorContains: "SMTP"})
	if !strings.Contains(query, "SELECT DISTINCT job_id FROM job_errors") {
		t.Error("query should have has_errors subquery")
	}
	if !strings.Contains(query, "error LIKE") {
		t.Error("query should have error_contains filter")
	}
}

func TestBuildQuerySortOrder(t *testing.T) {
	query, _, _, _, _ := BuildQuery(Filter{Sort: "priority", Order: "asc"})
	if !strings.Contains(query, "j.priority") {
		t.Error("query should sort by priority")
	}
	if !strings.Contains(query, "ASC") {
		t.Error("query should order ASC")
	}
}

func TestBuildQueryPagination(t *testing.T) {
	_, _, args, _, _ := BuildQuery(Filter{Limit: 25})
	// Last two args should be limit=25, offset=0
	if args[len(args)-2] != 25 {
		t.Errorf("limit = %v, want 25", args[len(args)-2])
	}
	if args[len(args)-1] != 0 {
		t.Errorf("offset = %v, want 0", args[len(args)-1])
	}
}

func TestBuildQueryWithChainFilters(t *testing.T) {
	query, _, args, _, _ := BuildQuery(Filter{ParentID: "job_parent", ChainID: "chain_123"})
	if !strings.Contains(query, "j.parent_id = ?") {
		t.Error("query should filter on parent_id")
	}
	if !strings.Contains(query, "j.chain_id = ?") {
		t.Error("query should filter on chain_id")
	}
	if args[0] != "job_parent" {
		t.Errorf("first arg = %v, want job_parent", args[0])
	}
	if args[1] != "chain_123" {
		t.Errorf("second arg = %v, want chain_123", args[1])
	}
}

func TestCursorEncodeDecode(t *testing.T) {
	encoded := EncodeCursor(42)
	decoded := DecodeCursor(encoded)
	if decoded != 42 {
		t.Errorf("DecodeCursor(EncodeCursor(42)) = %d, want 42", decoded)
	}
}

func TestDecodeCursorInvalid(t *testing.T) {
	if DecodeCursor("invalid-cursor") != 0 {
		t.Error("DecodeCursor of invalid cursor should return 0")
	}
}
