package main

import (
	"testing"
	"time"
)

func TestIsWriteQuery(t *testing.T) {
	cases := map[string]bool{
		"INSERT INTO users VALUES (1)":  true,
		"update users set x = 1":        true,
		"  DELETE FROM users WHERE 1=1": true,
		"REPLACE INTO users VALUES (1)": true,
		"SELECT * FROM users":           false,
		"SHOW TABLES":                   false,
		"DESCRIBE users":                false,
		"":                              false,
	}

	for query, want := range cases {
		if got := isWriteQuery(query); got != want {
			t.Errorf("isWriteQuery(%q) = %v, want %v", query, got, want)
		}
	}
}

func TestFormatValueNull(t *testing.T) {
	if got := formatValue(nil, kindText); got != "NULL" {
		t.Errorf("formatValue(nil, kindText) = %q, want %q", got, "NULL")
	}
}

func TestFormatValueBytes(t *testing.T) {
	if got := formatValue([]byte("hello"), kindText); got != "hello" {
		t.Errorf("formatValue([]byte) = %q, want %q", got, "hello")
	}
}

func TestFormatValueBinary(t *testing.T) {
	cases := []struct {
		name string
		in   []byte
		kind columnKind
		want string
	}{
		{"binary column", []byte{0x00, 0xab, 0x10}, kindBinary, "0x00AB10"},
		{"printable binary stays hex", []byte("abc"), kindBinary, "0x616263"},
		{"empty binary", []byte{}, kindBinary, ""},
		{"invalid utf8 in text column", []byte{0xff, 0xfe}, kindText, "0xFFFE"},
		{"utf8 text", []byte("héllo"), kindText, "héllo"},
		{"bit(1)", []byte{0x01}, kindBit, "1"},
		{"bit(16)", []byte{0x01, 0x02}, kindBit, "258"},
	}
	for _, c := range cases {
		if got := formatValue(c.in, c.kind); got != c.want {
			t.Errorf("%s: formatValue(%v) = %q, want %q", c.name, c.in, got, c.want)
		}
	}
}

func TestFormatValueTime(t *testing.T) {
	ts := time.Date(2024, 3, 5, 10, 30, 0, 0, time.UTC)
	want := "2024-03-05 10:30:00"
	if got := formatValue(ts, kindText); got != want {
		t.Errorf("formatValue(time.Time) = %q, want %q", got, want)
	}
	if got := formatValue(ts, kindDate); got != "2024-03-05" {
		t.Errorf("formatValue(time.Time, kindDate) = %q, want %q", got, "2024-03-05")
	}
}

func TestFormatValueNumeric(t *testing.T) {
	if got := formatValue(int64(42), kindText); got != "42" {
		t.Errorf("formatValue(int64) = %q, want %q", got, "42")
	}
}

// fakeRows feeds collectRows a fixed set of single-column rows.
type fakeRows struct {
	data []string
	pos  int
}

func (f *fakeRows) Next() bool {
	if f.pos >= len(f.data) {
		return false
	}
	f.pos++
	return true
}

func (f *fakeRows) Scan(dest ...interface{}) error {
	*(dest[0].(*interface{})) = f.data[f.pos-1]
	return nil
}

func (f *fakeRows) Err() error { return nil }

func TestCollectRowsNoCap(t *testing.T) {
	rows := &fakeRows{data: []string{"a", "b", "c"}}
	got, truncated, err := collectRows(rows, []columnKind{kindText}, 0)
	if err != nil {
		t.Fatalf("collectRows() error = %v", err)
	}
	if truncated {
		t.Errorf("collectRows() truncated = true, want false")
	}
	if len(got) != 3 || got[2][0] != "c" {
		t.Errorf("collectRows() = %v, want 3 rows ending in c", got)
	}
}

func TestCollectRowsCapHit(t *testing.T) {
	rows := &fakeRows{data: []string{"a", "b", "c"}}
	got, truncated, err := collectRows(rows, []columnKind{kindText}, 2)
	if err != nil {
		t.Fatalf("collectRows() error = %v", err)
	}
	if !truncated {
		t.Errorf("collectRows() truncated = false, want true")
	}
	if len(got) != 2 {
		t.Errorf("collectRows() returned %d rows, want 2", len(got))
	}
}

func TestCollectRowsCapExact(t *testing.T) {
	rows := &fakeRows{data: []string{"a", "b"}}
	got, truncated, err := collectRows(rows, []columnKind{kindText}, 2)
	if err != nil {
		t.Fatalf("collectRows() error = %v", err)
	}
	if truncated {
		t.Errorf("collectRows() truncated = true, want false when rows == cap")
	}
	if len(got) != 2 {
		t.Errorf("collectRows() returned %d rows, want 2", len(got))
	}
}
