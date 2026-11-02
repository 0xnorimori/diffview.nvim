package store

import (
	"database/sql"
	"time"
)

const (
	ResolvedTTL = 30 * 24 * time.Hour
	ReviewedTTL = 60 * 24 * time.Hour
	gcInterval  = 24 * time.Hour
)

type PruneResult struct {
	Comments int64
	Reviewed int64
}

func (s *Store) Prune(resolvedTTL, reviewedTTL time.Duration) (PruneResult, error) {
	var r PruneResult
	cutC := s.now().UTC().Add(-resolvedTTL).Format(time.RFC3339)
	res, err := s.db.Exec("DELETE FROM comments WHERE status = 'resolved' AND updated_at < ?", cutC)
	if err != nil {
		return r, err
	}
	r.Comments, _ = res.RowsAffected()
	cutR := s.now().UTC().Add(-reviewedTTL).Format(time.RFC3339)
	res, err = s.db.Exec(
		"DELETE FROM reviewed WHERE reviewed_at < ?", cutR)
	if err != nil {
		return r, err
	}
	r.Reviewed, _ = res.RowsAffected()
	return r, nil
}

func (s *Store) AutoGC() error {
	var last string
	err := s.db.QueryRow("SELECT value FROM meta WHERE key = 'last_gc'").Scan(&last)
	if err == nil {
		if t, perr := time.Parse(time.RFC3339, last); perr == nil && s.now().UTC().Sub(t) < gcInterval {
			return nil
		}
	} else if err != sql.ErrNoRows {
		return err
	}
	if _, err := s.Prune(ResolvedTTL, ReviewedTTL); err != nil {
		return err
	}
	_, err = s.db.Exec(
		"INSERT INTO meta (key, value) VALUES ('last_gc', ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value",
		s.ts(),
	)
	return err
}
