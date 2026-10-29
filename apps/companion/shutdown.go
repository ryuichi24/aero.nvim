package main

import (
	"net"
	"net/http"
	"sync"
)

// shutdownConnections tracks sockets with no active request. In particular,
// http.Server.Shutdown otherwise waits for StateNew sockets to age for five
// seconds, even when every active handler has already observed cancellation.
type shutdownConnections struct {
	mu       sync.Mutex
	pending  map[net.Conn]struct{}
	draining bool
}

func (c *shutdownConnections) track(conn net.Conn, state http.ConnState) {
	c.mu.Lock()

	pending := state == http.StateNew || state == http.StateIdle
	closeNow := pending && c.draining

	if pending && !c.draining {
		if c.pending == nil {
			c.pending = make(map[net.Conn]struct{})
		}

		c.pending[conn] = struct{}{}
	} else {
		delete(c.pending, conn)
	}

	c.mu.Unlock()

	if closeNow {
		_ = conn.Close()
	}
}

func (c *shutdownConnections) drain() {
	c.mu.Lock()
	c.draining = true
	connections := make([]net.Conn, 0, len(c.pending))

	for conn := range c.pending {
		connections = append(connections, conn)
	}

	c.pending = nil
	c.mu.Unlock()

	for _, conn := range connections {
		_ = conn.Close()
	}
}
