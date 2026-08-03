package store

import (
	"database/sql"
	"errors"
	"fmt"
	"time"

	_ "modernc.org/sqlite"
)

const schemaVersion = 1

var ErrNotFound = errors.New("comment not found")

var CommentTypes = map[string]bool{
	"issue":      true,
	"suggestion": true,
	"question":   true,
	"note":       true,
	"praise":     true,
}

type Store struct {
	db  *sql.DB
	now func() time.Time
}

type Comment struct {
	ID         int64   `json:"id"`
	File       string  `json:"file"`
	Side       string  `json:"side"`
	LineStart  int64   `json:"line_start"`
	LineEnd    int64   `json:"line_end"`
	Rev        string  `json:"rev"`
	LineText   string  `json:"line_text"`
	Type       string  `json:"type"`
	Text       string  `json:"text"`
	Status     string  `json:"status"`
	Resolution *string `json:"resolution"`
	CreatedAt  string  `json:"created_at"`
	UpdatedAt  string  `json:"updated_at"`
}

type AddParams struct {
	File      string
	Side      string
	LineStart int64
	LineEnd   int64
	Rev       string
	LineText  string
	Type      string
	Text      string
}

type ListFilter struct {
	Status string
	File   string
}

func Open(path string) (*Store, error) {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1)
	s := &Store{db: db, now: time.Now}
	for _, pragma := range []string{"PRAGMA journal_mode=WAL", "PRAGMA busy_timeout=5000"} {
		if _, err := db.Exec(pragma); err != nil {
			db.Close()
			return nil, err
		}
	}
	if err := s.migrate(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) SetNow(now func() time.Time) { s.now = now }

func (s *Store) Close() error { return s.db.Close() }

func (s *Store) ts() string { return s.now().UTC().Format(time.RFC3339) }

func (s *Store) migrate() error {
	var v int
	if err := s.db.QueryRow("PRAGMA user_version").Scan(&v); err != nil {
		return err
	}
	if v >= schemaVersion {
		return nil
	}
	_, err := s.db.Exec(`
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
CREATE TABLE reviewed (
  rev_range   TEXT NOT NULL,
  file        TEXT NOT NULL,
  reviewed_at TEXT NOT NULL,
  PRIMARY KEY (rev_range, file)
);
CREATE TABLE meta (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
);
PRAGMA user_version = 1;
`)
	return err
}

func (s *Store) Add(p AddParams) (int64, error) {
	if !CommentTypes[p.Type] {
		return 0, fmt.Errorf("invalid type %q", p.Type)
	}
	if p.Side == "" {
		p.Side = "new"
	}
	if p.LineEnd < p.LineStart {
		p.LineEnd = p.LineStart
	}
	ts := s.ts()
	res, err := s.db.Exec(
		`INSERT INTO comments (file, side, line_start, line_end, rev, line_text, type, text, status, resolution, created_at, updated_at)
		 VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'open', NULL, ?, ?)`,
		p.File, p.Side, p.LineStart, p.LineEnd, p.Rev, p.LineText, p.Type, p.Text, ts, ts,
	)
	if err != nil {
		return 0, err
	}
	return res.LastInsertId()
}

func (s *Store) List(f ListFilter) ([]Comment, error) {
	q := "SELECT id, file, side, line_start, line_end, rev, line_text, type, text, status, resolution, created_at, updated_at FROM comments WHERE 1=1"
	var args []any
	if f.Status != "" && f.Status != "all" {
		q += " AND status = ?"
		args = append(args, f.Status)
	}
	if f.File != "" {
		q += " AND file = ?"
		args = append(args, f.File)
	}
	q += " ORDER BY file, line_start, id"
	rows, err := s.db.Query(q, args...)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Comment
	for rows.Next() {
		var c Comment
		if err := rows.Scan(&c.ID, &c.File, &c.Side, &c.LineStart, &c.LineEnd, &c.Rev, &c.LineText, &c.Type, &c.Text, &c.Status, &c.Resolution, &c.CreatedAt, &c.UpdatedAt); err != nil {
			return nil, err
		}
		out = append(out, c)
	}
	return out, rows.Err()
}

func (s *Store) Resolve(id int64, note string) error {
	var n *string
	if note != "" {
		n = &note
	}
	return s.updateStatus(id, "resolved", n)
}

func (s *Store) Reopen(id int64) error {
	return s.updateStatus(id, "open", nil)
}

func (s *Store) Delete(id int64) error {
	res, err := s.db.Exec("DELETE FROM comments WHERE id = ?", id)
	if err != nil {
		return err
	}
	return oneRow(res)
}

func (s *Store) updateStatus(id int64, status string, note *string) error {
	res, err := s.db.Exec("UPDATE comments SET status = ?, resolution = ?, updated_at = ? WHERE id = ?", status, note, s.ts(), id)
	if err != nil {
		return err
	}
	return oneRow(res)
}

func oneRow(res sql.Result) error {
	n, err := res.RowsAffected()
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}
