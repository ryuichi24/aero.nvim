package main

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"math/big"
	"sort"
	"sync"
	"time"
)

type device struct {
	ID   string `json:"id"`
	Name string `json:"name"`
}

type state struct {
	host   host
	origin string

	mu              sync.Mutex
	devices         map[[32]byte]device
	code            string
	codeExpires     time.Time
	attempts        int
	store           *deviceStore
	pairingRevision uint64

	// Host reads are serialized independently of authentication/revocation.
	refreshMu sync.Mutex
	epoch     string
	revision  uint64
	digest    [32]byte
}

func randomToken(size int) string {
	bytes := make([]byte, size)
	if _, err := rand.Read(bytes); err != nil {
		panic("cryptographic randomness unavailable")
	}
	return base64.RawURLEncoding.EncodeToString(bytes)
}

func newState(h host, origin string) *state {
	s := &state{host: h, origin: origin, devices: make(map[[32]byte]device), epoch: randomToken(24)}
	s.newPairingCode()
	return s
}

func (s *state) newPairingCode() string {
	s.mu.Lock()
	defer s.mu.Unlock()
	number, err := rand.Int(rand.Reader, big.NewInt(1000000))
	if err != nil {
		panic("cryptographic randomness unavailable")
	}
	s.code = fmt.Sprintf("%06d", number.Int64())
	s.codeExpires = time.Now().Add(5 * time.Minute)
	s.attempts = 0
	s.pairingRevision++
	return s.code
}

var errPairingDenied = errors.New("pairing code invalid, expired, or consumed")

func (s *state) pair(code, name string) (string, device, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.attempts++
	supplied, expected := sha256.Sum256([]byte(code)), sha256.Sum256([]byte(s.code))
	if len(code) != 6 || s.attempts > 20 || !time.Now().Before(s.codeExpires) || subtle.ConstantTimeCompare(supplied[:], expected[:]) != 1 {
		return "", device{}, errPairingDenied
	}
	token := randomToken(32)
	nameRunes := []rune(name)
	if len(nameRunes) > 80 {
		nameRunes = nameRunes[:80]
	}
	d := device{ID: randomToken(12), Name: string(nameRunes)}
	next := s.copyDevices()
	next[sha256.Sum256([]byte(token))] = d
	if s.store != nil {
		if err := s.store.save(next); err != nil {
			return "", device{}, err
		}
	}
	s.devices = next
	s.codeExpires = time.Time{}
	s.pairingRevision++
	return token, d, nil
}

func (s *state) authenticate(token string) (device, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.devices[sha256.Sum256([]byte(token))]
	return d, ok
}

func (s *state) revoke(id string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	next := s.copyDevices()
	for hash, d := range next {
		if d.ID == id {
			delete(next, hash)
		}
	}
	if s.store != nil {
		if err := s.store.save(next); err != nil {
			return err
		}
	}
	s.devices = next
	s.pairingRevision++
	return nil
}

func (s *state) copyDevices() map[[32]byte]device {
	next := make(map[[32]byte]device, len(s.devices))
	for hash, d := range s.devices {
		next[hash] = d
	}
	return next
}

func (s *state) rememberDevices(path string) error {
	store, devices, err := openDeviceStore(path, s.origin)
	if err != nil {
		return err
	}
	s.store, s.devices = store, devices
	return nil
}

type pairingInfo struct {
	Revision  uint64   `json:"revision"`
	Origin    string   `json:"origin"`
	Code      string   `json:"code,omitempty"`
	ExpiresAt int64    `json:"expires_at,omitempty"`
	Devices   []device `json:"devices"`
}

func (s *state) pairingInfo() pairingInfo {
	s.mu.Lock()
	defer s.mu.Unlock()
	info := pairingInfo{Revision: s.pairingRevision, Origin: s.origin, Devices: make([]device, 0, len(s.devices))}
	if time.Now().Before(s.codeExpires) && s.attempts < 20 {
		info.Code, info.ExpiresAt = s.code, s.codeExpires.Unix()
	}
	for _, d := range s.devices {
		info.Devices = append(info.Devices, d)
	}
	sort.Slice(info.Devices, func(i, j int) bool { return info.Devices[i].ID < info.Devices[j].ID })
	return info
}

func (s *state) listDevices() []device {
	s.mu.Lock()
	defer s.mu.Unlock()
	result := make([]device, 0, len(s.devices))
	for _, d := range s.devices {
		result = append(result, d)
	}
	sort.Slice(result, func(i, j int) bool { return result[i].ID < result[j].ID })
	return result
}

func (s *state) refresh(ctx context.Context) map[string]json.RawMessage {
	s.refreshMu.Lock()
	defer s.refreshMu.Unlock()
	snapshot := make(map[string]json.RawMessage)
	response, err := s.host.Call(ctx, "snapshot", nil)
	if err == nil && response.Error == "" {
		err = json.Unmarshal(response.Result, &snapshot)
	}
	if err != nil || response.Error != "" || snapshot == nil || snapshot["sessions"] == nil {
		snapshot = map[string]json.RawMessage{
			"connected": json.RawMessage(`false`),
			"error":     json.RawMessage(`"Neovim unavailable; action outcomes may be unknown"`),
		}
	} else {
		snapshot["connected"] = json.RawMessage(`true`)
	}
	for _, field := range []string{"sessions", "inbox", "workspaces", "worktrees"} {
		if len(snapshot[field]) == 0 || string(snapshot[field]) == "null" {
			snapshot[field] = json.RawMessage(`[]`)
		}
	}
	encoded, _ := json.Marshal(snapshot)
	// Lua object key order can vary between reads. Canonicalize nested objects
	// before hashing so equivalent snapshots retain their cursor.
	var canonical any
	decoder := json.NewDecoder(bytes.NewReader(encoded))
	decoder.UseNumber()
	if decoder.Decode(&canonical) == nil {
		encoded, _ = json.Marshal(canonical)
	}
	digest := sha256.Sum256(encoded)
	if digest != s.digest {
		s.digest = digest
		s.revision++
	}
	snapshot["cursor"], _ = json.Marshal(fmt.Sprintf("%s:%d", s.epoch, s.revision))
	return snapshot
}
