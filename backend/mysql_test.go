package main

import "testing"

func TestColumnKindFor(t *testing.T) {
	cases := map[string]columnKind{
		"VARBINARY": kindBinary,
		"LONGBLOB":  kindBinary,
		"BINARY":    kindBinary,
		"BIT":       kindBit,
		"DATE":      kindDate,
		"VARCHAR":   kindText,
		"TEXT":      kindText,
		"INT":       kindText,
	}
	for name, want := range cases {
		if got := columnKindFor(name); got != want {
			t.Errorf("columnKindFor(%q) = %v, want %v", name, got, want)
		}
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
