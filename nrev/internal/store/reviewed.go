package store

type Reviewed struct {
	File      string
	ContentID string
}

func (s *Store) SetReviewed(file, contentID string, on bool) error {
	if !on {
		_, err := s.db.Exec("DELETE FROM reviewed WHERE file = ? AND content_id = ?", file, contentID)
		return err
	}
	_, err := s.db.Exec(
		`INSERT INTO reviewed (file, content_id, reviewed_at) VALUES (?, ?, ?)
		 ON CONFLICT(file, content_id) DO UPDATE SET reviewed_at = excluded.reviewed_at`,
		file, contentID, s.ts(),
	)
	return err
}

func (s *Store) ListReviewed() ([]Reviewed, error) {
	rows, err := s.db.Query("SELECT file, content_id FROM reviewed ORDER BY file, content_id")
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	var out []Reviewed
	for rows.Next() {
		var r Reviewed
		if err := rows.Scan(&r.File, &r.ContentID); err != nil {
			return nil, err
		}
		out = append(out, r)
	}
	return out, rows.Err()
}
