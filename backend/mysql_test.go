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
	if got := formatValue(nil); got != "NULL" {
		t.Errorf("formatValue(nil) = %q, want %q", got, "NULL")
	}
}

func TestFormatValueBytes(t *testing.T) {
	if got := formatValue([]byte("hello")); got != "hello" {
		t.Errorf("formatValue([]byte) = %q, want %q", got, "hello")
	}
}

func TestFormatValueTime(t *testing.T) {
	ts := time.Date(2024, 3, 5, 10, 30, 0, 0, time.UTC)
	want := "2024-03-05 10:30:00"
	if got := formatValue(ts); got != want {
		t.Errorf("formatValue(time.Time) = %q, want %q", got, want)
	}
}

func TestFormatValueNumeric(t *testing.T) {
	if got := formatValue(int64(42)); got != "42" {
		t.Errorf("formatValue(int64) = %q, want %q", got, "42")
	}
}

func TestBuildDSN(t *testing.T) {
	req := &Request{
		Host:     "db.internal",
		Port:     3307,
		User:     "alice",
		Password: "s3cret",
		Database: "shop",
	}

	dsn := buildDSN(req, "tcp")
	want := "alice:s3cret@tcp(db.internal:3307)/shop?parseTime=true"
	if dsn != want {
		t.Errorf("buildDSN() = %q, want %q", dsn, want)
	}
}

func TestBuildDSNDefaults(t *testing.T) {
	req := &Request{User: "root", Database: "shop"}
	dsn := buildDSN(req, "tcp")
	want := "root@tcp(localhost:3306)/shop?parseTime=true"
	if dsn != want {
		t.Errorf("buildDSN() = %q, want %q", dsn, want)
	}
}

func TestBuildDSNCustomNetwork(t *testing.T) {
	req := &Request{User: "root", Database: "shop", Host: "db", Port: 3306}
	dsn := buildDSN(req, proxyNetworkName)
	want := "root@abcql-socks(db:3306)/shop?parseTime=true"
	if dsn != want {
		t.Errorf("buildDSN() = %q, want %q", dsn, want)
	}
}
