package main

import (
	"testing"

	"github.com/go-sql-driver/mysql"
)

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
	want := "alice:s3cret@tcp(db.internal:3307)/shop?parseTime=true&tls=preferred"
	if dsn != want {
		t.Errorf("buildDSN() = %q, want %q", dsn, want)
	}
}

func TestBuildDSNDefaults(t *testing.T) {
	req := &Request{User: "root", Database: "shop"}
	dsn := buildDSN(req, "tcp")
	want := "root@tcp(localhost:3306)/shop?parseTime=true&tls=preferred"
	if dsn != want {
		t.Errorf("buildDSN() = %q, want %q", dsn, want)
	}
}

func TestBuildDSNCustomNetwork(t *testing.T) {
	req := &Request{User: "root", Database: "shop", Host: "db", Port: 3306}
	dsn := buildDSN(req, proxyNetworkName)
	want := "root@abcql-socks(db:3306)/shop?parseTime=true&tls=preferred"
	if dsn != want {
		t.Errorf("buildDSN() = %q, want %q", dsn, want)
	}
}

// The driver must accept the DSN and see the intended TLS mode: "preferred" by
// default, and exactly what the user asked for when the options name one.
func TestBuildDSNTLS(t *testing.T) {
	cases := []struct {
		name    string
		options map[string]string
		want    string
	}{
		{"default", nil, "preferred"},
		{"explicit true", map[string]string{"tls": "true"}, "true"},
		{"explicit false", map[string]string{"tls": "false"}, "false"},
		{"explicit skip-verify", map[string]string{"tls": "skip-verify"}, "skip-verify"},
		{"other options keep the default", map[string]string{"charset": "utf8mb4"}, "preferred"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			req := &Request{User: "u", Password: "p", Host: "db", Port: 3306, Database: "shop", Options: tc.options}
			cfg, err := mysql.ParseDSN(buildDSN(req, "tcp"))
			if err != nil {
				t.Fatalf("ParseDSN(buildDSN()) failed: %v", err)
			}
			if cfg.TLSConfig != tc.want {
				t.Errorf("TLSConfig = %q, want %q", cfg.TLSConfig, tc.want)
			}
			if tc.want == "preferred" && (cfg.TLS == nil || !cfg.AllowFallbackToPlaintext) {
				t.Errorf("tls=preferred should enable TLS with plaintext fallback, got TLS=%v fallback=%v",
					cfg.TLS, cfg.AllowFallbackToPlaintext)
			}
			if tc.want == "false" && cfg.TLS != nil {
				t.Errorf("tls=false should disable TLS, got %v", cfg.TLS)
			}
		})
	}
}

// A password with characters that are special in DSNs reaches the driver
// unchanged (the Lua side percent-decodes it before sending).
func TestBuildDSNPasswordSpecialCharacters(t *testing.T) {
	for _, password := range []string{"p@ss", "pa/ss", "p?a#s:s", "{x}@/y?z#", "trailing space "} {
		req := &Request{User: "u", Password: password, Host: "db", Port: 3306, Database: "shop"}
		cfg, err := mysql.ParseDSN(buildDSN(req, "tcp"))
		if err != nil {
			t.Fatalf("ParseDSN failed for password %q: %v", password, err)
		}
		if cfg.Passwd != password || cfg.User != "u" || cfg.Addr != "db:3306" || cfg.DBName != "shop" {
			t.Errorf("password %q parsed as user=%q passwd=%q addr=%q db=%q",
				password, cfg.User, cfg.Passwd, cfg.Addr, cfg.DBName)
		}
	}
}
