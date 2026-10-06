package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSetupConfigurationAndExplicitHTTP(t *testing.T) {
	path := filepath.Join(t.TempDir(), "companion.json")
	write := func(text string) {
		t.Helper()
		if err := os.WriteFile(path, []byte(text), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write(`{"socket":"/private/companion.sock","bind":"100.101.102.103","port":8765,"origin":"http://100.101.102.103:8765","allow_http":true}`)
	c, err := parseConfig([]string{"--config", path})
	if err != nil || !c.AllowHTTP || c.Bind != "100.101.102.103" || c.Socket != "/private/companion.sock" {
		t.Fatalf("setup-derived HTTP settings were not loaded: %+v, %v", c, err)
	}
	if _, err := parseConfig([]string{"--config", path, "--allow-http=false"}); err == nil {
		t.Fatal("explicit CLI disable did not restore HTTPS requirement")
	}
	c, err = parseConfig([]string{"--config", path, "--port", "9876", "--origin", "http://100.101.102.103:9876"})
	if err != nil || c.Port != 9876 || c.Origin != "http://100.101.102.103:9876" {
		t.Fatal("explicit CLI overrides ignored", err)
	}
	write(`{"socket":"/private/companion.sock","bind":"100.101.102.103","origin":"http://100.101.102.103:8765"}`)
	if _, err := parseConfig([]string{"--config", path}); err == nil {
		t.Fatal("direct HTTP was implicitly enabled")
	}
	if _, err := parseConfig([]string{"--config", path, "--allow-http"}); err != nil {
		t.Fatal("explicit CLI HTTP opt-in rejected", err)
	}
	for _, invalid := range []string{
		`{"socket":"/private/socket","allow_http":"true"}`,
		`{"socket":"/private/socket","unknown_option":true}`,
		`{"socket":"/private/socket"} {}`,
	} {
		write(invalid)
		if _, err := parseConfig([]string{"--config", path}); err == nil {
			t.Fatal("invalid configuration accepted")
		}
	}
	if _, err := parseConfig([]string{"--socket", "/private/socket", "--origin", "https://aero.example:8765", "--allow-http"}); err == nil {
		t.Fatal("HTTP opt-in bypassed HTTPS certificate configuration")
	}
}

func TestNeovimExportedConfigurationLoadsInGo(t *testing.T) {
	h := fixtureHost(t)
	c, err := parseConfig([]string{"--config", filepath.Join(filepath.Dir(h.path), "companion.json")})
	if err != nil {
		t.Fatal("Go could not load Neovim's exported setup settings:", err)
	}
	if c.Socket != h.path || c.AllowHTTP || c.Bind != "127.0.0.1" || c.Origin != "http://localhost:8765" {
		t.Fatalf("exported defaults changed: %+v", c)
	}
}
