package main

import (
	"bufio"
	"encoding/json"
	"io"
	"sync"
)

// This channel is inherited from Neovim, never exposed through the HTTP API.
type controlOutput struct {
	mu     sync.Mutex
	output io.Writer
}

func (c *controlOutput) send(event string, info pairingInfo, message string) {
	c.mu.Lock()
	defer c.mu.Unlock()
	_ = json.NewEncoder(c.output).Encode(struct {
		Event string `json:"event"`
		pairingInfo
		Message string `json:"message,omitempty"`
	}{event, info, message})
}

func controlConsole(b *bridge, input io.Reader, output *controlOutput, shutdown func()) {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 65536)
	for scanner.Scan() {
		var command struct {
			Method string `json:"method"`
			Device string `json:"device,omitempty"`
		}
		if err := json.Unmarshal(scanner.Bytes(), &command); err != nil {
			output.send("error", pairingInfo{}, "invalid companion control request")
			continue
		}
		switch command.Method {
		case "pair":
			b.state.newPairingCode()
			output.send("pairing", b.state.pairingInfo(), "")
		case "devices":
			output.send("devices", b.state.pairingInfo(), "")
		case "revoke":
			if command.Device == "" {
				output.send("error", pairingInfo{}, "device ID required")
				continue
			}
			if err := b.state.revoke(command.Device); err != nil {
				output.send("error", pairingInfo{}, "could not persist device revocation")
			} else {
				output.send("devices", b.state.pairingInfo(), "")
			}
		case "stop":
			shutdown()
			return
		default:
			output.send("error", pairingInfo{}, "unknown companion control request")
		}
	}
	// Losing the parent stops a managed bridge, even if Neovim is killed unexpectedly.
	shutdown()
}
