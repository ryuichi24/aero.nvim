package main

import (
	"bufio"
	"bytes"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestConsoleInterruptAndQuit(t *testing.T) {
	for _, input := range []string{"\x03", "partial command\x03", "quit\n", "quit\r\n"} {
		t.Run(fmt.Sprintf("%q", input), func(t *testing.T) {
			shutdowns := 0
			s := newState(hostFunc(fakeSnapshot), "http://localhost:8765")
			console(s, strings.NewReader(input), io.Discard, func() { shutdowns++ })
			if shutdowns != 1 {
				t.Fatalf("console input requested %d shutdowns, wanted 1", shutdowns)
			}
		})
	}
	// EOF can mean background startup with redirected stdin, not an explicit quit.
	shutdowns := 0
	s := newState(hostFunc(fakeSnapshot), "http://localhost:8765")
	_, d, _ := s.pair(s.code, "Test device")
	var output bytes.Buffer
	console(s, strings.NewReader("devices\npair\nrevoke "+d.ID+"\n"), &output, func() { shutdowns++ })
	if shutdowns != 0 || len(s.listDevices()) != 0 || !strings.Contains(output.String(), "Pairing code:") {
		t.Fatal("console controls or closed-stdin behavior regressed")
	}
}

// Run the actual CLI entry point in a subprocess so signals don't affect the test runner.
func TestCompanionProcessHelper(t *testing.T) {
	if os.Getenv("AERO_COMPANION_PROCESS_HELPER") != "1" {
		return
	}
	port := os.Getenv("AERO_COMPANION_PROCESS_PORT")
	os.Args = []string{"aero-companion", "--socket", "/nonexistent-aero-companion-shutdown.sock",
		"--port", port, "--origin", "http://127.0.0.1:" + port, "--devices-file", os.Getenv("AERO_COMPANION_TEST_DEVICES_FILE")}
	main()
}

type companionProcess struct {
	command *exec.Cmd
	stdin   io.WriteCloser
	stdout  *bufio.Scanner
	done    <-chan error
	origin  string
	code    string
	cookie  *http.Cookie
}

func startCompanionProcess(t *testing.T) *companionProcess {
	t.Helper()
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	command := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestCompanionProcessHelper$")
	devicesDirectory := t.TempDir()
	if err := os.Chmod(devicesDirectory, 0700); err != nil {
		cancel()
		t.Fatal(err)
	}
	command.Env = append(os.Environ(), "AERO_COMPANION_PROCESS_HELPER=1", "AERO_COMPANION_PROCESS_PORT="+strconv.Itoa(port),
		"AERO_COMPANION_TEST_DEVICES_FILE="+devicesDirectory+"/devices.json")
	stdin, err := command.StdinPipe()
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	stdout, err := command.StdoutPipe()
	if err != nil {
		cancel()
		t.Fatal(err)
	}
	command.Stderr = io.Discard
	if err := command.Start(); err != nil {
		cancel()
		t.Fatal(err)
	}
	done := make(chan error, 1)
	go func() { done <- command.Wait(); close(done) }()
	t.Cleanup(func() { cancel(); stdin.Close(); <-done })
	process := &companionProcess{command: command, stdin: stdin, stdout: bufio.NewScanner(stdout),
		done: done, origin: "http://127.0.0.1:" + strconv.Itoa(port)}
	for range 3 {
		if !process.stdout.Scan() {
			t.Fatal("CLI exited before startup completed")
		}
		if line := process.stdout.Text(); strings.HasPrefix(line, "Pairing code (single use, 5 minutes): ") {
			process.code = strings.TrimPrefix(line, "Pairing code (single use, 5 minutes): ")
		}
	}
	if process.code == "" {
		t.Fatal("CLI pairing prompt missing")
	}
	client := &http.Client{Timeout: time.Second}
	for deadline := time.Now().Add(3 * time.Second); time.Now().Before(deadline); {
		if response, err := client.Get(process.origin); err == nil {
			response.Body.Close()
			return process
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatal("CLI HTTP listener did not become ready")
	return nil
}

func (p *companionProcess) stream(t *testing.T) *http.Response {
	t.Helper()
	r, _ := http.NewRequest("POST", p.origin+"/api/pair", strings.NewReader(`{"code":"`+p.code+`"}`))
	r.Header.Set("Origin", p.origin)
	r.Header.Set("Content-Type", "application/json")
	client := &http.Client{Timeout: 10 * time.Second}
	response, err := client.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 || len(response.Cookies()) != 1 {
		t.Fatal("CLI pairing failed")
	}
	p.cookie = response.Cookies()[0]
	r, _ = http.NewRequest("GET", p.origin+"/api/events", nil)
	r.AddCookie(response.Cookies()[0])
	response, err = client.Do(r)
	if err != nil {
		t.Fatal(err)
	}
	if response.StatusCode != 200 {
		response.Body.Close()
		t.Fatal("CLI event stream failed")
	}
	return response
}

func TestCLISecondInterruptForcesExit(t *testing.T) {
	p := startCompanionProcess(t)
	stream := p.stream(t)
	defer stream.Body.Close()
	// A partially uploaded authenticated action keeps a handler blocked on its body.
	conn, err := net.Dial("tcp", strings.TrimPrefix(p.origin, "http://"))
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	_, err = fmt.Fprintf(conn, "POST /api/prompt HTTP/1.1\r\nHost: %s\r\nOrigin: %s\r\nCookie: %s\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{",
		strings.TrimPrefix(p.origin, "http://"), p.origin, p.cookie.String())
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(100 * time.Millisecond)
	if err := p.command.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	if !p.stdout.Scan() || p.stdout.Text() != "Stopping Aero companion..." {
		t.Fatal("graceful shutdown did not start")
	}
	if err := p.command.Process.Signal(os.Interrupt); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-p.done:
		exit, ok := err.(*exec.ExitError)
		if !ok {
			t.Fatalf("second interrupt did not force exit: %v", err)
		}
		status := exit.Sys().(syscall.WaitStatus)
		if !status.Signaled() || status.Signal() != syscall.SIGINT {
			t.Fatalf("unexpected forced-exit status: %v", status)
		}
	case <-time.After(3 * time.Second):
		t.Fatal("second interrupt was swallowed during shutdown")
	}
}

func TestCLIStopsWithActiveStream(t *testing.T) {
	for _, mode := range []string{"SIGINT", "SIGTERM", "raw Ctrl-C", "quit", "closed stdin then SIGINT"} {
		t.Run(mode, func(t *testing.T) {
			p := startCompanionProcess(t)
			stream := p.stream(t)
			defer stream.Body.Close()
			started := time.Now()
			switch mode {
			case "SIGINT":
				_ = p.command.Process.Signal(os.Interrupt)
			case "SIGTERM":
				_ = p.command.Process.Signal(syscall.SIGTERM)
			case "raw Ctrl-C":
				_, _ = io.WriteString(p.stdin, "partial draft\x03")
			case "quit":
				_, _ = io.WriteString(p.stdin, "quit\n")
			case "closed stdin then SIGINT":
				p.stdin.Close()
				select {
				case <-p.done:
					t.Fatal("closed stdin stopped the background bridge")
				case <-time.After(100 * time.Millisecond):
				}
				_ = p.command.Process.Signal(os.Interrupt)
			}
			select {
			case err := <-p.done:
				if err != nil {
					t.Fatalf("CLI shutdown failed: %v", err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("CLI failed to stop with an active event stream")
			}
			if time.Since(started) >= 3*time.Second {
				t.Fatal("CLI shutdown stalled")
			}
		})
	}
}
