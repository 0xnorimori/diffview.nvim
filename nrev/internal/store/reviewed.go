package store

func (s *Store) SetReviewed(revRange, file string, on bool) error {
	if !on {
		_, err := s.db.Exec("DELETE FROM reviewed WHERE rev_range = ? AND file = ?", revRange, file)
		return err
	}
	_, err := s.db.Exec(
		`INSERT INTO reviewed (rev_range, file, reviewed_at) VALUES (?, ?, ?)
		 ON CONFLICT(rev_range, file) DO UPDATE SET reviewed_at = excluded.reviewed_at`,
		revRange, file, s.ts(),
	)
	return err
}

func (s *Store) ListReviewed(revRange string) ([]string, error) {
	if _, err := s.db.Exec("UPDATE reviewed SET reviewed_at = ? WHERE rev_range = ?", s.ts(), revRange); err != nil {
		return nil, err
	}
	rows, err := s.db.Query("SELECT file FROM reviewed WHERE rev_range = ? ORDER BY file", revRange)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []string
	for rows.Next() {
		var f string
		if err := rows.Scan(&f); err != nil {
			return nil, err
		}
		out = append(out, f)
	}
	return out, rows.Err()
}
