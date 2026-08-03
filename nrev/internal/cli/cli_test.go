package cli

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func fixedClock(t *testing.T) {
	t.Helper()
	Now = func() time.Time { return time.Date(2026, 8, 3, 10, 0, 0, 0, time.UTC) }
	t.Cleanup(func() { Now = time.Now })
}

func run(args ...string) (string, string, int) {
	var out, errb bytes.Buffer
	code := Run(args, &out, &errb)
	return out.String(), errb.String(), code
}

func TestAddListResolveFlow(t *testing.T) {
	fixedClock(t)
	db := filepath.Join(t.TempDir(), "review.db")
	out, errOut, code := run("add", "--db", db, "--file", "internal/api/handler.go",
		"--line-start", "41", "--line-end", "44", "--rev", "WORKING",
		"--line-text", "if err != nil {", "--type", "issue", "--text", "error swallowed here")
	if code != 0 || out != "{\"id\":1}\n" {
		t.Fatalf("add: code=%d out=%q err=%q", code, out, errOut)
	}
	out, _, code = run("list", "--db", db, "--json")
	want := `[{"id":1,"file":"internal/api/handler.go","side":"new","line_start":41,"line_end":44,"rev":"WORKING","line_text":"if err != nil {","type":"issue","text":"error swallowed here","status":"open","resolution":null,"created_at":"2026-08-03T10:00:00Z","updated_at":"2026-08-03T10:00:00Z"}]` + "\n"
	if code != 0 || out != want {
		t.Fatalf("list golden mismatch:\n got: %q\nwant: %q", out, want)
	}
	if _, _, code = run("resolve", "1", "--db", db, "--note", "wrapped"); code != 0 {
		t.Fatal("resolve failed")
	}
	if out, _, _ = run("list", "--db", db, "--json"); out != "[]\n" {
		t.Fatalf("default open filter after resolve: %q", out)
	}
	out, _, _ = run("list", "--db", db, "--json", "--status", "resolved")
	if !strings.Contains(out, `"resolution":"wrapped"`) {
		t.Fatalf("resolved note missing: %q", out)
	}
	if _, _, code = run("reopen", "1", "--db", db); code != 0 {
		t.Fatal("reopen failed")
	}
	if _, _, code = run("delete", "1", "--db", db); code != 0 {
		t.Fatal("delete failed")
	}
	if out, _, _ = run("list", "--db", db, "--json", "--status", "all"); out != "[]\n" {
		t.Fatalf("after delete: %q", out)
	}
}

func TestMarkdown(t *testing.T) {
	fixedClock(t)
	db := filepath.Join(t.TempDir(), "review.db")
	run("add", "--db", db, "--file", "a.go", "--line-start", "41", "--line-end", "44",
		"--rev", "WORKING", "--line-text", "x", "--type", "issue", "--text", "err")
	run("add", "--db", db, "--file", "b.go", "--line-start", "10", "--side", "old",
		"--rev", "abc123", "--line-text", "y", "--type", "note", "--text", "old side")
	out, _, code := run("list", "--db", db, "--md", "--status", "all")
	want := "1. **[ISSUE]** `a.go:41-44` — err\n2. **[NOTE]** `~b.go:10` — old side\n"
	if code != 0 || out != want {
		t.Fatalf("md golden mismatch:\n got: %q\nwant: %q", out, want)
	}
}

func TestReviewedCLI(t *testing.T) {
	fixedClock(t)
	db := filepath.Join(t.TempDir(), "review.db")
	run("reviewed", "set", "a.go", "--db", db, "--rev-range", "abc")
	run("reviewed", "set", "b.go", "--db", db, "--rev-range", "abc")
	out, _, code := run("reviewed", "list", "--db", db, "--rev-range", "abc")
	if code != 0 || out != "a.go\nb.go\n" {
		t.Fatalf("reviewed list: %q", out)
	}
	run("reviewed", "unset", "a.go", "--db", db, "--rev-range", "abc")
	if out, _, _ = run("reviewed", "list", "--db", db, "--rev-range", "abc"); out != "b.go\n" {
		t.Fatalf("after unset: %q", out)
	}
}

func TestListNonexistentDBDoesNotCreateFile(t *testing.T) {
	db := filepath.Join(t.TempDir(), "review.db")
	out, errOut, code := run("list", "--db", db, "--json")
	if code != 0 || out != "[]\n" {
		t.Fatalf("list: code=%d out=%q err=%q", code, out, errOut)
	}
	if _, err := os.Stat(db); !os.IsNotExist(err) {
		t.Fatalf("db should not have been created: %v", err)
	}
}

func TestResolveNonexistentIDCreatesDB(t *testing.T) {
	fixedClock(t)
	db := filepath.Join(t.TempDir(), "review.db")
	_, errOut, code := run("resolve", "1", "--db", db)
	if code != 1 || !strings.Contains(errOut, "comment not found") {
		t.Fatalf("resolve: code=%d err=%q", code, errOut)
	}
	if _, err := os.Stat(db); err != nil {
		t.Fatalf("db should have been created: %v", err)
	}
}

func TestOutsideRepo(t *testing.T) {
	t.Chdir(t.TempDir())
	_, errOut, code := run("list", "--json")
	if code != 1 || !strings.Contains(errOut, "not in a git repository") {
		t.Fatalf("code=%d err=%q", code, errOut)
	}
}

func TestUnknownCommand(t *testing.T) {
	_, errOut, code := run("bogus")
	if code != 1 || !strings.Contains(errOut, "unknown command") {
		t.Fatalf("code=%d err=%q", code, errOut)
	}
}
