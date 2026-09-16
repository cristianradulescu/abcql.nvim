package main

import (
	"context"
	"fmt"
	"net"

	"github.com/go-sql-driver/mysql"
	"golang.org/x/net/proxy"
)

// proxyNetworkName is the custom network name registered with the mysql driver
// when a request asks to dial through a SOCKS proxy. Each backend process
// handles exactly one request then exits, so a fixed name is safe (no
// cross-request collisions to worry about).
const proxyNetworkName = "abcql-socks"

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
	dialer, err := proxy.SOCKS5("tcp", proxyAddr, nil, proxy.Direct)
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
