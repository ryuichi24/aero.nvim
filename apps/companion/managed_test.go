package main

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

type managedFixture struct {
	origin, code, directory string
	pid                     int
	command                 *exec.Cmd
	done                    chan error
	stopped                 bool
}

func startManagedFixture(t *testing.T, path string, port int) *managedFixture {
	t.Helper()
	directory := t.TempDir()
	if err := os.Chmod(directory, 0700); err != nil {
		t.Fatal(err)
	}
	cwd, _ := os.Getwd()
	command := exec.Command("nvim", "--headless", "-u", "NONE", "-l", "tests/fixtures/companion_host.lua")
	command.Dir = filepath.Dir(filepath.Dir(cwd))
	command.Env = append(os.Environ(), "AERO_COMPANION_TEST_DIR="+directory, "AERO_COMPANION_TEST_MANAGED=1",
		"AERO_COMPANION_DEVICE_STORE="+path, "AERO_COMPANION_BROWSER_PORT="+strconv.Itoa(port))
	command.Stdout, command.Stderr = io.Discard, io.Discard
	if err := command.Start(); err != nil {
		t.Fatal(err)
	}
	f := &managedFixture{directory: directory, command: command, done: make(chan error, 1)}
	go func() { f.done <- command.Wait(); close(f.done) }()
	t.Cleanup(func() {
		if !f.stopped {
			_ = command.Process.Kill()
			<-f.done
			if f.pid > 0 {
				_ = syscall.Kill(f.pid, syscall.SIGTERM)
			}
		}
	})
	for deadline := time.Now().Add(12 * time.Second); time.Now().Before(deadline); {
		if data, err := os.ReadFile(filepath.Join(directory, "managed-ready.json")); err == nil {
			var ready struct {
				Origin string
				Code   string
				PID    int
			}
			if err := json.Unmarshal(data, &ready); err != nil {
				t.Fatal(err)
			}
			f.origin, f.code, f.pid = ready.Origin, ready.Code, ready.PID
			return f
		}
		select {
		case err := <-f.done:
			t.Fatal("managed Neovim fixture exited before ready", err)
		default:
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("managed Neovim fixture startup timed out")
	return nil
}

func (f *managedFixture) stop(t *testing.T) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(f.directory, "quit"), []byte("quit"), 0600); err != nil {
		t.Fatal(err)
	}
	select {
	case err := <-f.done:
		if err != nil {
			t.Fatal("Neovim quit failed", err)
		}
		f.stopped = true
	case <-time.After(7 * time.Second):
		t.Fatal("Neovim did not quit")
	}
	for deadline := time.Now().Add(5 * time.Second); time.Now().Before(deadline); {
		if err := syscall.Kill(f.pid, 0); err != nil {
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatal("owned companion process remained alive after Neovim quit")
}

func TestManagedPairingSurvivesNeovimRestart(t *testing.T) {
	if _, err := os.Stat("aero-companion"); err != nil {
		t.Fatal("build the companion before managed integration tests (make test-companion)")
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	port := listener.Addr().(*net.TCPAddr).Port
	listener.Close()
	path := privateDevicesPath(t)
	first := startManagedFixture(t, path, port)
	jar, _ := cookiejar.New(nil)
	client := &http.Client{Jar: jar, Timeout: 5 * time.Second}
	request, _ := http.NewRequest("POST", first.origin+"/api/pair", strings.NewReader(`{"code":"`+first.code+`","name":"Remembered phone"}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", first.origin)
	response, err := client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 || response.Cookies()[0].MaxAge != deviceCookieAge {
		t.Fatal("six-digit managed pairing failed")
	}
	pairedCookie := response.Cookies()[0]
	first.stop(t)
	second := startManagedFixture(t, path, port)
	response, err = client.Get(second.origin + "/api/snapshot")
	if err != nil {
		t.Fatal(err)
	}
	var snapshot struct{ Connected bool }
	if err := json.NewDecoder(response.Body).Decode(&snapshot); err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 || !snapshot.Connected {
		t.Fatal("paired browser needed pairing again after Neovim restart")
	}
	request, _ = http.NewRequest("POST", second.origin+"/api/revoke", strings.NewReader(`{}`))
	request.Header.Set("Content-Type", "application/json")
	request.Header.Set("Origin", second.origin)
	response, err = client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 200 {
		t.Fatal("device revocation failed")
	}
	second.stop(t)
	third := startManagedFixture(t, path, port)
	request, _ = http.NewRequest("GET", third.origin+"/api/snapshot", nil)
	request.AddCookie(pairedCookie)
	response, err = client.Do(request)
	if err != nil {
		t.Fatal(err)
	}
	response.Body.Close()
	if response.StatusCode != 401 {
		t.Fatal("revoked device came back after Neovim restart")
	}
	third.stop(t)
}

// Managed popup/remembered-cookie browser demo, isolated from the user's real listener.
func TestManagedBrowserFixture(t *testing.T) {
	if os.Getenv("AERO_COMPANION_MANAGED_BROWSER_FIXTURE") != "1" {
		t.Skip("opt-in managed browser fixture")
	}
	port := 18765
	if value := os.Getenv("AERO_COMPANION_BROWSER_PORT"); value != "" {
		var err error
		port, err = strconv.Atoi(value)
		if err != nil || port < 1 || port > 65535 {
			t.Fatal("invalid managed fixture port")
		}
	}
	path := privateDevicesPath(t)
	fixture := startManagedFixture(t, path, port)
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	defer func() {
		if !fixture.stopped {
			fixture.stop(t)
		}
	}()
	readyPath := os.Getenv("AERO_COMPANION_BROWSER_READY_FILE")
	commandPath := readyPath + ".command"
	phase := 1
	publish := func() {
		if readyPath == "" {
			t.Log("Managed companion ready; code is in the Neovim popup")
			return
		}
		encoded, _ := json.Marshal(map[string]any{"origin": fixture.origin, "code": fixture.code, "phase": phase})
		if err := os.WriteFile(readyPath, encoded, 0600); err != nil {
			t.Fatal(err)
		}
	}
	publish()
	ticker := time.NewTicker(50 * time.Millisecond)
	defer ticker.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-ticker.C:
			if readyPath == "" {
				continue
			}
			if command, err := os.ReadFile(commandPath); err == nil {
				os.Remove(commandPath)
				if strings.TrimSpace(string(command)) == "restart" {
					fixture.stop(t)
					fixture = startManagedFixture(t, path, port)
					phase++
					publish()
				}
			}
		}
	}
}
