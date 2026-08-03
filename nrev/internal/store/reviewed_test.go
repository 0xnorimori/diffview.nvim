package store

import (
	"reflect"
	"testing"
	"time"
)

func TestReviewedRoundTrip(t *testing.T) {
	s, _ := testStore(t)
	for _, f := range []string{"a.go", "b.go", "a.go"} {
		if err := s.SetReviewed("base1", f, true); err != nil {
			t.Fatal(err)
		}
	}
	if err := s.SetReviewed("base2", "a.go", true); err != nil {
		t.Fatal(err)
	}
	files, err := s.ListReviewed("base1")
	if err != nil || !reflect.DeepEqual(files, []string{"a.go", "b.go"}) {
		t.Fatalf("list: %v %v", err, files)
	}
	if err := s.SetReviewed("base1", "a.go", false); err != nil {
		t.Fatal(err)
	}
	files, _ = s.ListReviewed("base1")
	if !reflect.DeepEqual(files, []string{"b.go"}) {
		t.Fatalf("after unset: %v", files)
	}
}

func TestPruneAndAutoGC(t *testing.T) {
	s, clock := testStore(t)
	if _, err := s.Add(AddParams{File: "a.go", LineStart: 1, Rev: "WORKING", LineText: "l", Type: "issue", Text: "stays open"}); err != nil {
		t.Fatal(err)
	}
	rid, _ := s.Add(AddParams{File: "a.go", LineStart: 2, Rev: "WORKING", LineText: "l", Type: "note", Text: "gets resolved"})
	if err := s.Resolve(rid, ""); err != nil {
		t.Fatal(err)
	}
	if err := s.SetReviewed("touched", "a.go", true); err != nil {
		t.Fatal(err)
	}
	if err := s.SetReviewed("untouched", "b.go", true); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(31 * 24 * time.Hour)
	if _, err := s.ListReviewed("touched"); err != nil {
		t.Fatal(err)
	}
	if err := s.AutoGC(); err != nil {
		t.Fatal(err)
	}
	all, _ := s.List(ListFilter{Status: "all"})
	if len(all) != 1 || all[0].Text != "stays open" {
		t.Fatalf("open comment must survive, resolved must be pruned: %+v", all)
	}
	if n := countReviewed(t, s, "untouched"); n != 1 {
		t.Fatalf("untouched only 31d old, must survive: %d", n)
	}
	*clock = clock.Add(30 * 24 * time.Hour)
	if err := s.AutoGC(); err != nil {
		t.Fatal(err)
	}
	if n := countReviewed(t, s, "untouched"); n != 0 {
		t.Fatalf("untouched 61d old, must be pruned: %d", n)
	}
	if n := countReviewed(t, s, "touched"); n != 1 {
		t.Fatalf("touched was refreshed by ListReviewed 30d ago, must survive: %d", n)
	}
}

func countReviewed(t *testing.T, s *Store, revRange string) int {
	t.Helper()
	var n int
	if err := s.db.QueryRow("SELECT COUNT(*) FROM reviewed WHERE rev_range = ?", revRange).Scan(&n); err != nil {
		t.Fatal(err)
	}
	return n
}
