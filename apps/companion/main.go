package main

import (
	"bufio"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

var version = "dev"

func main() {
	if len(os.Args) == 2 && os.Args[1] == "--version" {
		fmt.Println("aero-companion " + version)
		return
	}
	c, err := parseConfig(os.Args[1:])
	if errors.Is(err, flag.ErrHelp) {
		return
	}
	if err != nil {
		if c.StdioControl {
			(&controlOutput{output: os.Stdout}).send("error", pairingInfo{}, err.Error())
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
	if err := runBridge(c); err != nil {
		if c.StdioControl {
			(&controlOutput{output: os.Stdout}).send("error", pairingInfo{}, err.Error())
		} else {
			fmt.Fprintln(os.Stderr, err)
		}
		os.Exit(1)
	}
}

func runBridge(c config) error {
	b := newBridge(unixHost{path: c.Socket}, c.Origin)
	b.recordingsDir = filepath.Join(filepath.Dir(c.DevicesFile), "recordings")
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	server := httpServer(c, b, ctx)
	listener, err := net.Listen("tcp", server.Addr)
	if err != nil {
		return errors.New("could not start companion listener; check bind address and port")
	}
	defer listener.Close()
	if c.Cert != "" {
		certificate, err := tls.LoadX509KeyPair(c.Cert, c.Key)
		if err != nil {
			return errors.New("could not load companion HTTPS certificate and key")
		}
		server.TLSConfig.Certificates = []tls.Certificate{certificate}
		listener = tls.NewListener(listener, server.TLSConfig)
	}
	if err := b.state.rememberDevices(c.DevicesFile); err != nil {
		return err
	}
	defer b.state.store.close()
	control := &controlOutput{output: os.Stdout}
	if c.StdioControl {
		b.onChange = func(event string) { control.send(event, b.state.pairingInfo(), "") }
	}
	shutdownDone := make(chan struct{})
	go func() {
		defer close(shutdownDone)
		<-ctx.Done()
		// Restore default signal handling: a second Ctrl-C can force an immediate exit.
		stop()
		if !c.StdioControl {
			fmt.Println("Stopping Aero companion...")
		}
		shutdown, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdown); err != nil {
			_ = server.Close()
		}
	}()
	if c.StdioControl {
		control.send("ready", b.state.pairingInfo(), "")
		go controlConsole(b, os.Stdin, control, stop)
	} else {
		fmt.Printf("Aero companion: %s\nPairing code (single use, 5 minutes): %s\n", c.Origin, b.state.code)
		fmt.Println("Console commands: pair, devices, revoke DEVICE_ID, quit. Ctrl-C stops the bridge. Paired devices are remembered.")
		go console(b.state, os.Stdin, os.Stdout, stop)
	}
	err = server.Serve(listener)
	if err != nil && !errors.Is(err, http.ErrServerClosed) {
		return errors.New("companion HTTP(S) listener failed")
	}
	if errors.Is(err, http.ErrServerClosed) {
		<-shutdownDone
	}
	return nil
}

func console(s *state, input io.Reader, output io.Writer, shutdown func()) {
	reader := bufio.NewReader(input)
	line := make([]byte, 0, 128)
	oversized := false
	for {
		value, err := reader.ReadByte()
		if err != nil {
			return // Closed stdin must not stop an intentionally backgrounded bridge.
		}
		if value == '\x03' {
			// Embedded/raw terminals can deliver Ctrl-C as ETX instead of generating SIGINT.
			shutdown()
			return
		}
		if value != '\n' && value != '\r' {
			if len(line) < 64*1024 {
				line = append(line, value)
			} else {
				oversized = true
			}
			continue
		}
		command := strings.Fields(string(line))
		line = line[:0]
		if oversized {
			oversized = false
			continue
		}
		if len(command) == 1 && command[0] == "quit" {
			shutdown()
			return
		}
		if len(command) == 1 && command[0] == "pair" {
			fmt.Fprintln(output, "Pairing code:", s.newPairingCode())
		} else if len(command) == 1 && command[0] == "devices" {
			encoded, _ := json.Marshal(s.listDevices())
			fmt.Fprintln(output, string(encoded))
		} else if len(command) == 2 && command[0] == "revoke" {
			if err := s.revoke(command[1]); err != nil {
				fmt.Fprintln(output, "Could not persist device revocation")
			}
		}
	}
}
