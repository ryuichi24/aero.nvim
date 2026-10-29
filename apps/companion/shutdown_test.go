package main

import (
	"context"
	"io"
	"net"
	"net/http"
	"testing"
	"time"
)

func TestShutdownClosesUnstartedConnections(t *testing.T) {
	connections := &shutdownConnections{}
	accepted := make(chan struct{}, 2)
	server := httpServer(config{}, http.NotFoundHandler(), context.Background())
	server.ConnState = func(conn net.Conn, state http.ConnState) {
		connections.track(conn, state)

		if state == http.StateNew {
			accepted <- struct{}{}
		}
	}

	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}

	done := make(chan error, 1)

	go func() { done <- server.Serve(listener) }()

	t.Cleanup(func() { _ = server.Close(); <-done })

	// Cover both a speculative connection and an incomplete first request.
	for _, header := range []string{"", "GET / HTTP/1.1\r\nHost:"} {
		conn, err := net.Dial("tcp", listener.Addr().String())
		if err != nil {
			t.Fatal(err)
		}

		t.Cleanup(func() { _ = conn.Close() })

		if _, err := io.WriteString(conn, header); err != nil {
			t.Fatal(err)
		}

		select {
		case <-accepted:
		case <-time.After(time.Second):
			t.Fatal("server did not accept the unstarted connection")
		}
	}

	connections.drain()

	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	if err := server.Shutdown(ctx); err != nil {
		t.Fatalf("unstarted connections stalled shutdown: %v", err)
	}
}

func TestShutdownConnectionTransitions(t *testing.T) {
	connections := &shutdownConnections{}

	active, peer := net.Pipe()
	defer active.Close()
	defer peer.Close()

	connections.track(active, http.StateNew)
	connections.track(active, http.StateActive)
	connections.drain()

	if err := active.SetReadDeadline(time.Now().Add(time.Second)); err != nil {
		t.Fatal("drain closed an active request")
	}

	connections.track(active, http.StateIdle)

	if err := active.SetReadDeadline(time.Now().Add(time.Second)); err == nil {
		t.Fatal("completed request remained open while draining")
	}

	late, latePeer := net.Pipe()
	defer late.Close()
	defer latePeer.Close()

	connections.track(late, http.StateNew)

	if err := late.SetReadDeadline(time.Now().Add(time.Second)); err == nil {
		t.Fatal("connection accepted during shutdown remained open")
	}
}
