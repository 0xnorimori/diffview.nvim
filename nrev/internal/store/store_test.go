package store

import (
	"database/sql"
	"os"
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

func TestOpenRecoversFromPartialMigration(t *testing.T) {
	path := filepath.Join(t.TempDir(), "review.db")
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`
CREATE TABLE comments (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  file        TEXT NOT NULL,
  side        TEXT NOT NULL DEFAULT 'new' CHECK (side IN ('old','new')),
  line_start  INTEGER NOT NULL,
  line_end    INTEGER NOT NULL,
  rev         TEXT NOT NULL,
  line_text   TEXT NOT NULL,
  type        TEXT NOT NULL CHECK (type IN ('issue','suggestion','question','note','praise')),
  text        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
  resolution  TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
`); err != nil {
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatalf("open after partial migration: %v", err)
	}
	t.Cleanup(func() { s.Close() })
	id, err := s.Add(AddParams{File: "a.go", LineStart: 1, Rev: "WORKING", LineText: "x", Type: "issue", Text: "t"})
	if err != nil {
		t.Fatal(err)
	}
	cs, err := s.List(ListFilter{Status: "all"})
	if err != nil || len(cs) != 1 || cs[0].ID != id {
		t.Fatalf("list after recovery: %v %+v", err, cs)
	}
}

func TestReadLeavesNoSidecarFiles(t *testing.T) {
	path := filepath.Join(t.TempDir(), "review.db")
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec("PRAGMA journal_mode=WAL; CREATE TABLE t (x INTEGER)"); err != nil {
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if _, err := s.List(ListFilter{Status: "all"}); err != nil {
		t.Fatal(err)
	}
	for _, side := range []string{"-wal", "-shm"} {
		if _, err := os.Stat(path + side); !os.IsNotExist(err) {
			t.Fatalf("%s exists while reading: %v", side, err)
		}
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

func TestConcurrentOpenWaitsForLocks(t *testing.T) {
	path := filepath.Join(t.TempDir(), "review.db")
	first, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	first.Close()
	errs := make(chan error, 16)
	for range 16 {
		go func() {
			s, err := Open(path)
			if err == nil {
				_, err = s.Add(AddParams{File: "a.go", LineStart: 1, Rev: "WORKING", LineText: "x", Type: "note", Text: "t"})
				s.Close()
			}
			errs <- err
		}()
	}
	for range 16 {
		if err := <-errs; err != nil {
			t.Fatal(err)
		}
	}
}

func TestMigrateV1DropsReviewed(t *testing.T) {
	path := filepath.Join(t.TempDir(), "review.db")
	raw, err := sql.Open("sqlite", path)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := raw.Exec(`
CREATE TABLE comments (
  id          INTEGER PRIMARY KEY AUTOINCREMENT,
  file        TEXT NOT NULL,
  side        TEXT NOT NULL DEFAULT 'new' CHECK (side IN ('old','new')),
  line_start  INTEGER NOT NULL,
  line_end    INTEGER NOT NULL,
  rev         TEXT NOT NULL,
  line_text   TEXT NOT NULL,
  type        TEXT NOT NULL CHECK (type IN ('issue','suggestion','question','note','praise')),
  text        TEXT NOT NULL,
  status      TEXT NOT NULL DEFAULT 'open' CHECK (status IN ('open','resolved')),
  resolution  TEXT,
  created_at  TEXT NOT NULL,
  updated_at  TEXT NOT NULL
);
CREATE TABLE reviewed (rev_range TEXT NOT NULL, file TEXT NOT NULL, reviewed_at TEXT NOT NULL, PRIMARY KEY (rev_range, file));
CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
INSERT INTO comments (file, line_start, line_end, rev, line_text, type, text, created_at, updated_at)
  VALUES ('a.go', 1, 1, 'WORKING', 'x', 'note', 'kept', '2026-08-01T00:00:00Z', '2026-08-01T00:00:00Z');
INSERT INTO reviewed VALUES ('abc', 'a.go', '2026-08-01T00:00:00Z');
PRAGMA user_version = 1;
`); err != nil {
		t.Fatal(err)
	}
	if err := raw.Close(); err != nil {
		t.Fatal(err)
	}

	s, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { s.Close() })
	if got, err := s.ListReviewed(); err != nil || len(got) != 0 {
		t.Fatalf("reviewed after migration: %v %v", err, got)
	}
	if cs, _ := s.List(ListFilter{Status: "all"}); len(cs) != 1 || cs[0].Text != "kept" {
		t.Fatalf("comments after migration: %+v", cs)
	}
	var v int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil || v != 2 {
		t.Fatalf("user_version: %v %d", err, v)
	}
}
