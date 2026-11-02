package cli

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"github.com/ggfarmco/diffview.nvim/nrev/internal/render"
	"github.com/ggfarmco/diffview.nvim/nrev/internal/store"
)

var Now = time.Now

const usage = "usage: nrev add|list|resolve|reopen|delete|reviewed|prune"

func Run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 1
	}
	var err error
	switch cmd, rest := args[0], args[1:]; cmd {
	case "add":
		err = runAdd(rest, stdout)
	case "list":
		err = runList(rest, stdout)
	case "resolve":
		err = runStatus(rest, "resolve")
	case "reopen":
		err = runStatus(rest, "reopen")
	case "delete":
		err = runStatus(rest, "delete")
	case "reviewed":
		err = runReviewed(rest, stdout)
	case "prune":
		err = runPrune(rest, stdout)
	default:
		err = fmt.Errorf("unknown command %q\n%s", cmd, usage)
	}
	if err != nil {
		fmt.Fprintln(stderr, "nrev:", err)
		return 1
	}
	return 0
}

func resolveDBPath(dbPath string) (string, error) {
	if dbPath != "" {
		return dbPath, nil
	}
	out, err := exec.Command("git", "rev-parse", "--git-dir").Output()
	if err != nil {
		return "", fmt.Errorf("not in a git repository")
	}
	return filepath.Join(strings.TrimSpace(string(out)), "review.db"), nil
}

func open(dbPath string) (*store.Store, error) {
	path, err := resolveDBPath(dbPath)
	if err != nil {
		return nil, err
	}
	return openPath(path)
}

func openPath(path string) (*store.Store, error) {
	s, err := store.Open(path)
	if err != nil {
		return nil, err
	}
	s.SetNow(Now)
	return s, nil
}

func relToRepo(file string, skip bool) (string, error) {
	if file == "" || skip {
		return file, nil
	}
	out, err := exec.Command("git", "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return file, nil
	}
	abs, err := filepath.Abs(file)
	if err != nil {
		return "", err
	}
	rel, err := filepath.Rel(strings.TrimSpace(string(out)), abs)
	if err != nil || strings.HasPrefix(rel, "..") {
		return file, nil
	}
	return rel, nil
}

func runAdd(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("add", flag.ContinueOnError)
	db := fs.String("db", "", "")
	file := fs.String("file", "", "")
	lineStart := fs.Int64("line-start", 0, "")
	lineEnd := fs.Int64("line-end", 0, "")
	side := fs.String("side", "new", "")
	rev := fs.String("rev", "WORKING", "")
	lineText := fs.String("line-text", "", "")
	typ := fs.String("type", "", "")
	text := fs.String("text", "", "")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if *file == "" || *lineStart == 0 || *typ == "" || *text == "" {
		return fmt.Errorf("add requires --file, --line-start, --type, --text")
	}
	rel, err := relToRepo(*file, *db != "")
	if err != nil {
		return err
	}
	s, err := open(*db)
	if err != nil {
		return err
	}
	defer s.Close()
	id, err := s.Add(store.AddParams{
		File: rel, Side: *side, LineStart: *lineStart, LineEnd: *lineEnd,
		Rev: *rev, LineText: *lineText, Type: *typ, Text: *text,
	})
	if err != nil {
		return err
	}
	_ = s.AutoGC()
	return json.NewEncoder(stdout).Encode(map[string]int64{"id": id})
}

func runList(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("list", flag.ContinueOnError)
	db := fs.String("db", "", "")
	status := fs.String("status", "open", "")
	file := fs.String("file", "", "")
	jsonOut := fs.Bool("json", false, "")
	mdOut := fs.Bool("md", false, "")
	if err := fs.Parse(args); err != nil {
		return err
	}
	if !*jsonOut && !*mdOut {
		return fmt.Errorf("list requires --json or --md")
	}
	path, err := resolveDBPath(*db)
	if err != nil {
		return err
	}
	if _, statErr := os.Stat(path); os.IsNotExist(statErr) {
		if *jsonOut {
			return render.JSON(stdout, nil)
		}
		return nil
	}
	rel, err := relToRepo(*file, *db != "")
	if err != nil {
		return err
	}
	s, err := openPath(path)
	if err != nil {
		return err
	}
	defer s.Close()
	cs, err := s.List(store.ListFilter{Status: *status, File: rel})
	if err != nil {
		return err
	}
	if *jsonOut {
		return render.JSON(stdout, cs)
	}
	return render.Markdown(stdout, cs)
}

func runStatus(args []string, verb string) error {
	if len(args) == 0 {
		return fmt.Errorf("%s requires an id", verb)
	}
	id, err := strconv.ParseInt(args[0], 10, 64)
	if err != nil {
		return fmt.Errorf("invalid id %q", args[0])
	}
	fs := flag.NewFlagSet(verb, flag.ContinueOnError)
	db := fs.String("db", "", "")
	note := fs.String("note", "", "")
	if err := fs.Parse(args[1:]); err != nil {
		return err
	}
	s, err := open(*db)
	if err != nil {
		return err
	}
	defer s.Close()
	switch verb {
	case "resolve":
		err = s.Resolve(id, *note)
	case "reopen":
		err = s.Reopen(id)
	case "delete":
		err = s.Delete(id)
	}
	if err != nil {
		return err
	}
	_ = s.AutoGC()
	return nil
}

func runReviewed(args []string, stdout io.Writer) error {
	if len(args) == 0 {
		return fmt.Errorf("reviewed requires set|unset|list")
	}
	sub, rest := args[0], args[1:]
	var file string
	if sub == "set" || sub == "unset" {
		if len(rest) == 0 || strings.HasPrefix(rest[0], "-") {
			return fmt.Errorf("reviewed %s requires FILE", sub)
		}
		file, rest = rest[0], rest[1:]
	}
	fs := flag.NewFlagSet("reviewed", flag.ContinueOnError)
	db := fs.String("db", "", "")
	contentID := fs.String("content-id", "", "")
	if err := fs.Parse(rest); err != nil {
		return err
	}
	switch sub {
	case "set", "unset":
		if *contentID == "" {
			return fmt.Errorf("--content-id is required")
		}
		rel, err := relToRepo(file, *db != "")
		if err != nil {
			return err
		}
		s, err := open(*db)
		if err != nil {
			return err
		}
		defer s.Close()
		if err := s.SetReviewed(rel, *contentID, sub == "set"); err != nil {
			return err
		}
		_ = s.AutoGC()
		return nil
	case "list":
		path, err := resolveDBPath(*db)
		if err != nil {
			return err
		}
		if _, statErr := os.Stat(path); os.IsNotExist(statErr) {
			return nil
		}
		s, err := openPath(path)
		if err != nil {
			return err
		}
		defer s.Close()
		rows, err := s.ListReviewed()
		if err != nil {
			return err
		}
		for _, r := range rows {
			fmt.Fprintf(stdout, "%s\t%s\n", r.File, r.ContentID)
		}
		return nil
	default:
		return fmt.Errorf("reviewed: unknown subcommand %q", sub)
	}
}

func runPrune(args []string, stdout io.Writer) error {
	fs := flag.NewFlagSet("prune", flag.ContinueOnError)
	db := fs.String("db", "", "")
	resolved := fs.String("resolved-older-than", "30d", "")
	reviewed := fs.String("reviewed-older-than", "60d", "")
	if err := fs.Parse(args); err != nil {
		return err
	}
	rTTL, err := parseDur(*resolved)
	if err != nil {
		return err
	}
	vTTL, err := parseDur(*reviewed)
	if err != nil {
		return err
	}
	s, err := open(*db)
	if err != nil {
		return err
	}
	defer s.Close()
	res, err := s.Prune(rTTL, vTTL)
	if err != nil {
		return err
	}
	fmt.Fprintf(stdout, "pruned %d comments, %d reviewed entries\n", res.Comments, res.Reviewed)
	return nil
}

func parseDur(v string) (time.Duration, error) {
	if strings.HasSuffix(v, "d") {
		n, err := strconv.Atoi(strings.TrimSuffix(v, "d"))
		if err != nil {
			return 0, fmt.Errorf("invalid duration %q", v)
		}
		return time.Duration(n) * 24 * time.Hour, nil
	}
	return time.ParseDuration(v)
}
