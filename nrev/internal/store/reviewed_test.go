package store

import (
	"reflect"
	"testing"
	"time"
)

func TestReviewedVersions(t *testing.T) {
	s, _ := testStore(t)
	for _, id := range []string{"x", "y", "x"} {
		if err := s.SetReviewed("a.go", id, true); err != nil {
			t.Fatal(err)
		}
	}
	got, err := s.ListReviewed()
	if err != nil || !reflect.DeepEqual(got, []Reviewed{{"a.go", "x"}, {"a.go", "y"}}) {
		t.Fatalf("list: %v %v", err, got)
	}
	if err := s.SetReviewed("a.go", "x", false); err != nil {
		t.Fatal(err)
	}
	got, _ = s.ListReviewed()
	if !reflect.DeepEqual(got, []Reviewed{{"a.go", "y"}}) {
		t.Fatalf("after unset: %v", got)
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
	if err := s.SetReviewed("a.go", "old", true); err != nil {
		t.Fatal(err)
	}
	*clock = clock.Add(31 * 24 * time.Hour)
	if err := s.SetReviewed("a.go", "fresh", true); err != nil {
		t.Fatal(err)
	}
	if err := s.AutoGC(); err != nil {
		t.Fatal(err)
	}
	all, _ := s.List(ListFilter{Status: "all"})
	if len(all) != 1 || all[0].Text != "stays open" {
		t.Fatalf("open comment must survive, resolved must be pruned: %+v", all)
	}
	*clock = clock.Add(30 * 24 * time.Hour)
	if err := s.AutoGC(); err != nil {
		t.Fatal(err)
	}
	got, _ := s.ListReviewed()
	if !reflect.DeepEqual(got, []Reviewed{{"a.go", "fresh"}}) {
		t.Fatalf("only the 61d old row must be pruned: %v", got)
	}
}
