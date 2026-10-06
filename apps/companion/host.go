package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"net"
	"time"
)

const maxRequest = 128 * 1024
const maxResponse = 16 * 1024 * 1024

type hostResponse struct {
	Result json.RawMessage `json:"result,omitempty"`
	Error  string          `json:"error,omitempty"`
}

type host interface {
	Call(context.Context, string, any) (hostResponse, error)
}

// unixHost uses Aero's private allowlisted protocol, never Neovim RPC.
type unixHost struct{ path string }

func (h unixHost) Call(ctx context.Context, method string, params any) (hostResponse, error) {
	var response hostResponse
	message, err := json.Marshal(struct {
		Method string `json:"method"`
		Params any    `json:"params,omitempty"`
	}{method, params})
	if err != nil || len(message)+1 > maxRequest {
		return response, errors.New("invalid or oversized host request")
	}
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	conn, err := (&net.Dialer{}).DialContext(ctx, "unix", h.path)
	if err != nil {
		return response, err
	}
	defer conn.Close()
	stop := context.AfterFunc(ctx, func() { _ = conn.Close() })
	defer stop()
	deadline, _ := ctx.Deadline()
	_ = conn.SetDeadline(deadline)
	if _, err = conn.Write(append(message, '\n')); err != nil {
		return response, err
	}
	scanner := bufio.NewScanner(conn)
	scanner.Buffer(make([]byte, 4096), maxResponse)
	if !scanner.Scan() {
		if err = scanner.Err(); err == nil {
			err = errors.New("host disconnected before responding")
		}
		return response, err
	}
	err = json.Unmarshal(scanner.Bytes(), &response)
	if err == nil && response.Error == "" && len(response.Result) == 0 {
		err = errors.New("invalid host response")
	}
	return response, err
}
