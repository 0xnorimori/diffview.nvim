package render

import (
	"encoding/json"
	"fmt"
	"io"
	"strings"

	"github.com/ggfarmco/diffview.nvim/nrev/internal/store"
)

func JSON(w io.Writer, cs []store.Comment) error {
	if cs == nil {
		cs = []store.Comment{}
	}
	return json.NewEncoder(w).Encode(cs)
}

func Markdown(w io.Writer, cs []store.Comment) error {
	for i, c := range cs {
		loc := fmt.Sprintf("%s:%d", c.File, c.LineStart)
		if c.LineEnd > c.LineStart {
			loc = fmt.Sprintf("%s:%d-%d", c.File, c.LineStart, c.LineEnd)
		}
		if c.Side == "old" {
			loc = "~" + loc
		}
		if _, err := fmt.Fprintf(w, "%d. **[%s]** `%s` — %s\n", i+1, strings.ToUpper(c.Type), loc, c.Text); err != nil {
			return err
		}
	}
	return nil
}
