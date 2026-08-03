package store

import (
	"path/filepath"
	"testing"
	"time"
)

func testStore(t *testing.T) (*Store, *time.Time) {
	t.Helper()
	s, err := Open(filepath.Join(t.TempDir(), "review.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	now := time.Date(2026, 8, 3, 10, 0, 0, 0, time.UTC)
	cur := &now
	s.SetNow(func() time.Time { return *cur })
	return s, cur
}

func TestAddListRoundTrip(t *testing.T) {
	s, _ := testStore(t)
	id, err := s.Add(AddParams{File: "a.go", LineStart: 5, Rev: "WORKING", LineText: "x := 1", Type: "issue", Text: "wrong"})
	if err != nil || id != 1 {
		t.Fatalf("add: %v id=%d", err, id)
	}
	if _, err := s.Add(AddParams{File: "b.go", Side: "old", LineStart: 2, LineEnd: 4, Rev: "abc123", LineText: "y", Type: "praise", Text: "nice"}); err != nil {
		t.Fatal(err)
	}
	cs, err := s.List(ListFilter{Status: "all"})
	if err != nil {
		t.Fatal(err)
	}
	if len(cs) != 2 {
		t.Fatalf("want 2, got %d", len(cs))
	}
	c := cs[0]
	if c.Side != "new" || c.LineEnd != 5 || c.Status != "open" || c.Resolution != nil || c.CreatedAt != "2026-08-03T10:00:00Z" {
		t.Fatalf("defaults: %+v", c)
	}
	if cs[1].Side != "old" || cs[1].LineEnd != 4 {
		t.Fatalf("range/side: %+v", cs[1])
	}
	only, err := s.List(ListFilter{Status: "all", File: "a.go"})
	if err != nil || len(only) != 1 || only[0].File != "a.go" {
		t.Fatalf("file filter: %v %+v", err, only)
	}
}

func TestAddInvalidType(t *testing.T) {
	s, _ := testStore(t)
	if _, err := s.Add(AddParams{File: "a.go", LineStart: 1, Rev: "WORKING", Type: "nit", Text: "x"}); err == nil {
		t.Fatal("want error for invalid type")
	}
}

func TestResolveReopenLifecycle(t *testing.T) {
	s, clock := testStore(t)
	id, err := s.Add(AddParams{File: "a.go", LineStart: 1, Rev: "WORKING", LineText: "l", Type: "issue", Text: "t"})
	if err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(time.Hour)
	if err := s.Resolve(id, "done"); err != nil {
		t.Fatal(err)
	}
	cs, _ := s.List(ListFilter{Status: "resolved"})
	if len(cs) != 1 || cs[0].Resolution == nil || *cs[0].Resolution != "done" || cs[0].UpdatedAt != "2026-08-03T11:00:00Z" {
		t.Fatalf("resolved: %+v", cs)
	}
	if err := s.Reopen(id); err != nil {
		t.Fatal(err)
	}
	cs, _ = s.List(ListFilter{Status: "open"})
	if len(cs) != 1 || cs[0].Resolution != nil {
		t.Fatalf("reopened: %+v", cs)
	}
	if err := s.Resolve(99, ""); err != ErrNotFound {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}

func TestDelete(t *testing.T) {
	s, _ := testStore(t)
	id, _ := s.Add(AddParams{File: "a.go", LineStart: 1, Rev: "WORKING", LineText: "l", Type: "note", Text: "t"})
	if err := s.Delete(id); err != nil {
		t.Fatal(err)
	}
	if cs, _ := s.List(ListFilter{Status: "all"}); len(cs) != 0 {
		t.Fatalf("still present: %+v", cs)
	}
	if err := s.Delete(id); err != ErrNotFound {
		t.Fatalf("want ErrNotFound, got %v", err)
	}
}
