package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"testing"
)

func privateDevicesPath(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	if err := os.Chmod(dir, 0700); err != nil {
		t.Fatal(err)
	}
	return filepath.Join(dir, "devices.json")
}

func TestSixDigitCodeAndPersistentDevices(t *testing.T) {
	path := privateDevicesPath(t)
	origin := "http://100.101.102.103:8765"
	first := newBridge(hostFunc(fakeSnapshot), origin)
	if !regexp.MustCompile(`^[0-9]{6}$`).MatchString(first.state.code) {
		t.Fatal("pairing code is not six decimal digits")
	}
	if err := first.state.rememberDevices(path); err != nil {
		t.Fatal(err)
	}
	first.state.code = "000042"
	token, d, err := first.state.pair("000042", "Phone")
	if err != nil {
		t.Fatal("leading-zero pairing failed", err)
	}
	if _, _, err := first.state.pair("000042", "Duplicate"); err == nil {
		t.Fatal("code was not single-use")
	}
	cookie := first.cookie(token, deviceCookieAge)
	if cookie.MaxAge != deviceCookieAge || cookie.Expires.IsZero() || !cookie.HttpOnly {
		t.Fatal("device cookie is not persistent and HttpOnly")
	}
	encoded, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(encoded, []byte(token)) || bytes.Contains(encoded, []byte(`"code"`)) {
		t.Fatal("credential or pairing code persisted as plaintext")
	}
	info, _ := os.Stat(path)
	if info.Mode().Perm() != 0600 {
		t.Fatal("device file is not private")
	}
	first.state.store.close()

	second := newBridge(hostFunc(fakeSnapshot), origin)
	if err := second.state.rememberDevices(path); err != nil {
		t.Fatal(err)
	}
	if loaded, ok := second.state.authenticate(token); !ok || loaded.ID != d.ID {
		t.Fatal("restart forgot the paired device")
	}
	hash := sha256.Sum256([]byte(token))
	if _, ok := second.state.authenticate(hex.EncodeToString(hash[:])); ok {
		t.Fatal("stored hash was accepted as a credential")
	}
	r := httptest.NewRequest("GET", origin+"/api/snapshot", nil)
	r.AddCookie(cookie)
	w := httptest.NewRecorder()
	second.ServeHTTP(w, r)
	if w.Code != 200 || w.Result().Cookies()[0].MaxAge != deviceCookieAge {
		t.Fatal("remembered browser failed authentication/renewal after restart")
	}
	if err := second.state.revoke(d.ID); err != nil {
		t.Fatal(err)
	}
	second.state.store.close()
	third := newBridge(hostFunc(fakeSnapshot), origin)
	if err := third.state.rememberDevices(path); err != nil {
		t.Fatal(err)
	}
	defer third.state.store.close()
	if _, ok := third.state.authenticate(token); ok {
		t.Fatal("revoked device returned after restart")
	}
	w = httptest.NewRecorder()
	third.ServeHTTP(w, r)
	if w.Code != 401 {
		t.Fatal("revoked browser remained authenticated")
	}
}

func TestDevicePersistenceFailureAndOriginIsolation(t *testing.T) {
	path := privateDevicesPath(t)
	s := newState(hostFunc(fakeSnapshot), "http://localhost:8765")
	if err := s.rememberDevices(path); err != nil {
		t.Fatal(err)
	}
	if _, _, err := openDeviceStore(path, s.origin); err == nil {
		t.Fatal("concurrent device store was not locked")
	}
	token, d, err := s.pair(s.code, "Phone")
	if err != nil {
		t.Fatal(err)
	}
	s.store.close()
	if _, _, err := openDeviceStore(path, "http://localhost:9876"); err == nil {
		t.Fatal("device store crossed origins")
	}
	if err := s.rememberDevices(path); err != nil {
		t.Fatal(err)
	}
	defer s.store.close()
	goodPath := s.store.path
	s.store.path = filepath.Join(filepath.Dir(path), "missing", "devices.json")
	if err := s.revoke(d.ID); err == nil {
		t.Fatal("failed revocation persistence reported success")
	}
	if _, ok := s.authenticate(token); !ok {
		t.Fatal("failed revocation changed authoritative state")
	}
	s.newPairingCode()
	if _, _, err := s.pair(s.code, "New phone"); err == nil {
		t.Fatal("failed pairing persistence reported success")
	}
	if len(s.listDevices()) != 1 {
		t.Fatal("failed pairing left an unremembered credential active")
	}
	s.store.path = goodPath
	b1, b2 := newBridge(hostFunc(fakeSnapshot), s.origin), newBridge(hostFunc(fakeSnapshot), "http://localhost:9876")
	if b1.cookie(token, 0).Name == b2.cookie(token, 0).Name {
		t.Fatal("different origins share a browser cookie name")
	}
}

func TestManagedControlAndNoPublicAdministration(t *testing.T) {
	b := newBridge(hostFunc(fakeSnapshot), "http://localhost:8765")
	var output bytes.Buffer
	stopped := false
	controlConsole(b, strings.NewReader("{\"method\":\"pair\"}\n{\"method\":\"devices\"}\n{\"method\":\"stop\"}\n"),
		&controlOutput{output: &output}, func() { stopped = true })
	if !stopped || !strings.Contains(output.String(), `"event":"pairing"`) || !strings.Contains(output.String(), `"event":"devices"`) {
		t.Fatal("private parent control failed")
	}
	stopped = false
	controlConsole(b, strings.NewReader(""), &controlOutput{output: io.Discard}, func() { stopped = true })
	if !stopped {
		t.Fatal("managed bridge did not stop when parent closed stdin")
	}
	token, _, err := b.state.pair(b.state.code, "Test phone")
	if err != nil {
		t.Fatal(err)
	}
	for _, route := range []string{"/api/devices", "/api/pairing-code"} {
		r := httptest.NewRequest(http.MethodGet, b.state.origin+route, nil)
		r.AddCookie(b.cookie(token, deviceCookieAge))
		w := httptest.NewRecorder()
		b.ServeHTTP(w, r)
		if w.Code != 404 {
			t.Fatal("parent-only control exposed over HTTP")
		}
	}
}
