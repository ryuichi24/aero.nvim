package main

import (
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"sort"
	"syscall"
)

type savedDevice struct {
	Hash string `json:"hash"`
	ID   string `json:"id"`
	Name string `json:"name"`
}

type deviceFile struct {
	Version int           `json:"version"`
	Origin  string        `json:"origin"`
	Devices []savedDevice `json:"devices"`
}

type deviceStore struct {
	path, origin string
	lock         *os.File
}

func defaultDevicesFile(origin string) (string, error) {
	directory, err := os.UserConfigDir()
	if err != nil {
		return "", errors.New("could not locate companion device storage")
	}
	hash := sha256.Sum256([]byte(origin))
	return filepath.Join(directory, "aero-companion", "devices-"+hex.EncodeToString(hash[:8])+".json"), nil
}

func openDeviceStore(path, origin string) (*deviceStore, map[[32]byte]device, error) {
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return nil, nil, errors.New("could not create device storage directory")
	}
	info, err := os.Stat(directory)
	if err != nil || info.Mode().Perm()&0077 != 0 {
		return nil, nil, errors.New("device storage directory must be private (0700)")
	}
	for _, name := range []string{path, path + ".lock"} {
		if info, err := os.Lstat(name); err == nil && (!info.Mode().IsRegular() || info.Mode().Perm()&0077 != 0) {
			return nil, nil, errors.New("device storage files must be regular private files (0600)")
		} else if err != nil && !os.IsNotExist(err) {
			return nil, nil, errors.New("could not inspect device storage")
		}
	}
	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, nil, errors.New("could not lock device storage")
	}
	if err := syscall.Flock(int(lock.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		lock.Close()
		return nil, nil, errors.New("another companion is using this device store")
	}
	store := &deviceStore{path: path, origin: origin, lock: lock}
	devices, err := store.load()
	if err != nil {
		store.close()
		return nil, nil, err
	}
	return store, devices, nil
}

func (store *deviceStore) close() {
	_ = syscall.Flock(int(store.lock.Fd()), syscall.LOCK_UN)
	_ = store.lock.Close()
}

func (store *deviceStore) load() (map[[32]byte]device, error) {
	devices := make(map[[32]byte]device)
	file, err := os.Open(store.path)
	if os.IsNotExist(err) {
		return devices, nil
	}
	if err != nil {
		return nil, errors.New("could not read remembered devices")
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || info.Size() > 1024*1024 {
		return nil, errors.New("invalid remembered device file")
	}
	var saved deviceFile
	decoder := json.NewDecoder(io.LimitReader(file, 1024*1024))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&saved); err != nil || decoder.Decode(new(any)) != io.EOF || saved.Version != 1 || saved.Origin != store.origin {
		return nil, errors.New("remembered devices are invalid or belong to a different origin")
	}
	ids := make(map[string]bool)
	for _, record := range saved.Devices {
		bytes, err := hex.DecodeString(record.Hash)
		if err != nil || len(bytes) != 32 || record.ID == "" || ids[record.ID] {
			return nil, errors.New("invalid remembered device record")
		}
		var hash [32]byte
		copy(hash[:], bytes)
		if _, found := devices[hash]; found {
			return nil, errors.New("duplicate remembered device record")
		}
		ids[record.ID] = true
		devices[hash] = device{ID: record.ID, Name: record.Name}
	}
	return devices, nil
}

func (store *deviceStore) save(devices map[[32]byte]device) error {
	saved := deviceFile{Version: 1, Origin: store.origin, Devices: make([]savedDevice, 0, len(devices))}
	for hash, d := range devices {
		saved.Devices = append(saved.Devices, savedDevice{Hash: hex.EncodeToString(hash[:]), ID: d.ID, Name: d.Name})
	}
	sort.Slice(saved.Devices, func(i, j int) bool { return saved.Devices[i].ID < saved.Devices[j].ID })
	encoded, err := json.MarshalIndent(saved, "", "  ")
	if err != nil {
		return errors.New("could not encode remembered devices")
	}
	if len(encoded) > 1024*1024 {
		return errors.New("remembered device storage is full")
	}
	file, err := os.CreateTemp(filepath.Dir(store.path), ".devices-*.tmp")
	if err != nil {
		return errors.New("could not persist remembered devices")
	}
	defer os.Remove(file.Name())
	defer file.Close()
	if _, err := file.Write(encoded); err != nil {
		return errors.New("could not persist remembered devices")
	}
	if err := file.Sync(); err != nil {
		return errors.New("could not persist remembered devices")
	}
	if err := file.Close(); err != nil {
		return errors.New("could not persist remembered devices")
	}
	if err := os.Rename(file.Name(), store.path); err != nil {
		return errors.New("could not persist remembered devices")
	}
	return nil
}
