package main

import (
	"context"
	"fmt"
	"net"
	"time"

	"github.com/go-sql-driver/mysql"
	"golang.org/x/net/proxy"
)

// proxyNetworkName is the custom network name registered with the mysql driver
// when a request asks to dial through a SOCKS proxy. Each backend process
// serves exactly one connection (one request for "exec", one session for
// "serve"), so a fixed name is safe: nothing else in the process registers
// a different proxy under it.
const proxyNetworkName = "abcql-socks"

// directNetworkName is the custom network registered for a direct TCP
// connection, so it gets the same keepalive as a proxied one.
const directNetworkName = "abcql-tcp"

// keepAlive is the TCP keepalive period of a session's connection: a dead
// peer or a dropped network is noticed instead of hanging a statement forever.
const keepAlive = 30 * time.Second

// registerDirectDialer registers a plain TCP dialer with keepalive and
// returns the network name to use in the driver DSN.
func registerDirectDialer() string {
	dialer := &net.Dialer{KeepAlive: keepAlive}
	mysql.RegisterDialContext(directNetworkName, func(ctx context.Context, addr string) (net.Conn, error) {
		return dialer.DialContext(ctx, "tcp", addr)
	})
	return directNetworkName
}

// registerProxyDialer wires a SOCKS5 dialer into the mysql driver's dial
// registry and returns the network name to use in the driver DSN, or "" if
// no proxy was configured.
func registerProxyDialer(cfg *ProxyConfig) (string, error) {
	if cfg == nil {
		return "", nil
	}

	if cfg.Type != "socks5" {
		return "", fmt.Errorf("unsupported proxy type %q (only socks5 is supported)", cfg.Type)
	}

	proxyAddr := net.JoinHostPort(cfg.Host, fmt.Sprintf("%d", cfg.Port))
	dialer, err := proxy.SOCKS5("tcp", proxyAddr, nil, &net.Dialer{KeepAlive: keepAlive})
	if err != nil {
		return "", fmt.Errorf("failed to create SOCKS5 dialer: %w", err)
	}

	contextDialer, ok := dialer.(proxy.ContextDialer)
	if !ok {
		// proxy.SOCKS5 always returns a ContextDialer in practice, but fall
		// back to a context-less dial rather than panic if that ever changes.
		mysql.RegisterDialContext(proxyNetworkName, func(_ context.Context, addr string) (net.Conn, error) {
			return dialer.Dial("tcp", addr)
		})
		return proxyNetworkName, nil
	}

	mysql.RegisterDialContext(proxyNetworkName, func(ctx context.Context, addr string) (net.Conn, error) {
		return contextDialer.DialContext(ctx, "tcp", addr)
	})

	return proxyNetworkName, nil
}
