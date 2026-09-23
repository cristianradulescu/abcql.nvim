package main

import (
	"database/sql"
	"fmt"
	"strconv"
	"strings"

	_ "github.com/go-sql-driver/mysql"
)

// buildDSN converts a Request's structured connection fields into a
// go-sql-driver/mysql DSN string. Returns the network name to plug into the
// DSN too, since a SOCKS proxy (if configured) is wired in via a custom
// registered network rather than DSN host/port rewriting.
func buildDSN(req *Request, network string) string {
	var b strings.Builder

	if req.User != "" {
		b.WriteString(req.User)
		if req.Password != "" {
			b.WriteString(":")
			b.WriteString(req.Password)
		}
		b.WriteString("@")
	}

	host := req.Host
	if host == "" {
		host = "localhost"
	}
	port := int(req.Port)
	if port == 0 {
		port = 3306
	}

	b.WriteString(network)
	b.WriteString("(")
	b.WriteString(host)
	b.WriteString(":")
	b.WriteString(strconv.Itoa(port))
	b.WriteString(")/")
	b.WriteString(req.Database)

	params := []string{"parseTime=true"}
	for k, v := range req.Options {
		params = append(params, fmt.Sprintf("%s=%s", k, v))
	}
	b.WriteString("?")
	b.WriteString(strings.Join(params, "&"))

	return b.String()
}

// execMySQL connects to MySQL, runs the request's SQL, and returns a fully
// populated Response.
func execMySQL(req *Request) (*Response, error) {
	network := "tcp"
	if req.Proxy != nil {
		var err error
		network, err = registerProxyDialer(req.Proxy)
		if err != nil {
			return nil, err
		}
	}

	db, err := sql.Open("mysql", buildDSN(req, network))
	if err != nil {
		return nil, fmt.Errorf("failed to open connection: %w", err)
	}
	defer db.Close()

	return runSQL(db, req, mysqlColumnKind)
}

// mysqlColumnKind maps a column's driver type name to the columnKind used for
// formatting. The driver reports binary-collation string types as
// BINARY/VARBINARY/*BLOB and their text counterparts as CHAR/*TEXT.
func mysqlColumnKind(ct *sql.ColumnType) columnKind {
	return columnKindFor(ct.DatabaseTypeName())
}

func columnKindFor(typeName string) columnKind {
	switch typeName {
	case "BINARY", "VARBINARY", "TINYBLOB", "BLOB", "MEDIUMBLOB", "LONGBLOB", "GEOMETRY":
		return kindBinary
	case "BIT":
		return kindBit
	case "DATE":
		return kindDate
	default:
		return kindText
	}
}
