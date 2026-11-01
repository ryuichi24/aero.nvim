package knowledge

import (
	"archive/zip"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
	"time"
)

func source(t *testing.T, content string) string {
	t.Helper()

	filename := filepath.Join(t.TempDir(), "managed copy")
	if err := os.WriteFile(filename, []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}

	return filename
}

func officeSource(t *testing.T, files map[string]string) string {
	t.Helper()
	filename := filepath.Join(t.TempDir(), "managed-office")

	f, err := os.Create(filename)
	if err != nil {
		t.Fatal(err)
	}

	archive := zip.NewWriter(f)

	for name, content := range files {
		writer, err := archive.Create(name)
		if err != nil {
			t.Fatal(err)
		}

		if _, err := writer.Write([]byte(content)); err != nil {
			t.Fatal(err)
		}
	}

	if err := archive.Close(); err != nil {
		t.Fatal(err)
	}

	if err := f.Close(); err != nil {
		t.Fatal(err)
	}

	return filename
}

func TestTextAndCSV(t *testing.T) {
	filename := source(t, "# Findings\n"+strings.Repeat("Evidence\n", 35))

	d, err := Extract(context.Background(), filename, "report.MD", Options{})
	if err != nil {
		t.Fatal(err)
	}

	if len(d.Chunks) != 2 || d.Chunks[1].Location["line"] != 31 {
		t.Fatalf("bad text chunks: %#v", d)
	}

	first := d.Version

	if err := os.WriteFile(filename, []byte("changed"), 0o600); err != nil {
		t.Fatal(err)
	}

	d, err = Extract(context.Background(), filename, "report.md", Options{})
	if err != nil || first == d.Version {
		t.Fatalf("version did not change: %v", err)
	}

	d, err = Extract(context.Background(), source(t, "name,value\n\"First, customer\",10\n\"Two\nlines\",20\n"), "survey.csv", Options{})
	if err != nil {
		t.Fatal(err)
	}

	if !reflect.DeepEqual(d.Tables[0].Rows[2], []string{"Two\nlines", "20"}) || d.Chunks[2].Location["row"] != 3 {
		t.Fatalf("bad CSV: %#v", d)
	}
}

// The test executable doubles as an adapter so tests need no language runtime.
func TestAdapterProcess(t *testing.T) {
	if len(os.Args) < 2 || !strings.HasPrefix(os.Args[len(os.Args)-1], "adapter-") {
		return
	}

	mode := os.Args[len(os.Args)-1]
	if mode == "adapter-sleep" {
		time.Sleep(time.Minute)
		return
	}

	if mode == "adapter-fail" {
		_, _ = fmt.Fprint(os.Stderr, "decoder missing")

		os.Exit(2)
	}

	if mode == "adapter-invalid" {
		fmt.Print("not JSON")
		os.Exit(0)
	}

	var request map[string]any
	if err := json.NewDecoder(os.Stdin).Decode(&request); err != nil {
		os.Exit(3)
	}

	if mode == "adapter-embed" {
		fmt.Print(`{"model":"test","vectors":[[1,0]]}`)
		os.Exit(0)
	}

	filename, ok := request["path"].(string)
	if !ok || !filepath.IsAbs(filename) || request["protocol_version"] != float64(1) || request["extension"] != ".custom" {
		os.Exit(4)
	}

	if _, err := os.ReadFile(filename); err != nil {
		os.Exit(5)
	}

	fmt.Print(`{"version":"untrusted","embedding_model":"untrusted","chunks":[{"text":"Custom evidence","location":{"section":"test"},"vector":[99]}],"tables":[],"issues":["Partial coverage"]}`)
	os.Exit(0)
}

func adapterCommand(mode string) []string {
	return []string{os.Args[0], "-test.run=^TestAdapterProcess$", "--", "adapter-" + mode}
}

func TestCustomAdaptersAndEmbeddings(t *testing.T) {
	filename := source(t, "anything")
	options := Options{Extractors: []Adapter{{Extensions: []string{".custom"}, Command: adapterCommand("ok")}}}

	d, err := Extract(context.Background(), filename, "data.CUSTOM", options)
	if err != nil {
		t.Fatal(err)
	}

	if d.Version == "untrusted" || d.EmbeddingModel != "" || len(d.Chunks[0].Vector) != 0 || d.Chunks[0].Location["section"] != "test" {
		t.Fatalf("bad adapter output: %#v", d)
	}

	options.EmbeddingCommand = adapterCommand("embed")

	d, err = Extract(context.Background(), filename, "data.custom", options)
	if err != nil || d.EmbeddingModel != "test" || !reflect.DeepEqual(d.Chunks[0].Vector, []float64{1, 0}) {
		t.Fatalf("bad embedding: %#v %v", d, err)
	}

	options.EmbeddingCommand = adapterCommand("fail")

	d, err = Extract(context.Background(), filename, "data.custom", options)
	if err != nil || len(d.Issues) != 2 || !strings.Contains(d.Issues[1], "decoder missing") {
		t.Fatalf("embedding fallback failed: %#v %v", d, err)
	}

	for _, mode := range []string{"fail", "invalid"} {
		options.Extractors[0].Command = adapterCommand(mode)
		if _, err := Extract(context.Background(), filename, "data.custom", options); err == nil {
			t.Fatalf("accepted %s adapter", mode)
		}
	}

	options.Extractors[0].Command = adapterCommand("sleep")

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Millisecond)
	defer cancel()

	if _, err := Extract(ctx, filename, "data.custom", options); err == nil {
		t.Fatal("ignored cancellation")
	}
}

func TestValidationAndOverride(t *testing.T) {
	filename := source(t, "anything")
	if _, err := Extract(context.Background(), filename, "data.bin", Options{}); err == nil {
		t.Fatal("accepted unsupported format")
	}

	options := Options{Extractors: []Adapter{{Extensions: []string{".txt"}, Command: adapterCommand("fail")}}}
	if _, err := Extract(context.Background(), filename, "data.txt", options); err == nil || !strings.Contains(err.Error(), "decoder missing") {
		t.Fatalf("override not used: %v", err)
	}

	options.Extractors = append(options.Extractors, options.Extractors[0])
	if _, err := Extract(context.Background(), filename, "data.txt", options); err == nil {
		t.Fatal("accepted duplicate adapter")
	}

	for _, raw := range []string{`{}`, `{"chunks":[],"tables":[],"issues":null}`, `{"chunks":[{"text":"text","location":{"line":"bad"}}],"tables":[],"issues":[]}`, `{"chunks":[{"text":"text","location":{"page":0}}],"tables":[],"issues":[]}`} {
		var d Document
		if err := json.Unmarshal([]byte(raw), &d); err != nil {
			t.Fatal(err)
		}

		if err := validate(d); err == nil {
			t.Fatalf("accepted invalid payload: %s", raw)
		}
	}

	for _, raw := range []string{
		`{"chunks":[],"tables":[],"issues":[null]}`,
		`{"chunks":[],"tables":[{"rows":[]}],"issues":[]}`,
		`{"chunks":[],"tables":[{"name":"data","rows":[[null]]}],"issues":[]}`,
	} {
		if _, err := decodePayload([]byte(raw)); err == nil {
			t.Fatalf("accepted invalid wire payload: %s", raw)
		}
	}
}

func fakeTool(t *testing.T, directory, name, script string) {
	t.Helper()

	if err := os.WriteFile(filepath.Join(directory, name), []byte("#!/bin/sh\n"+script), 0o700); err != nil {
		t.Fatal(err)
	}
}

func TestMediaTools(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("PATH", directory)

	filename := source(t, "image")
	if _, err := Extract(context.Background(), filename, "image.png", Options{}); err == nil || !strings.Contains(err.Error(), "requires tesseract") {
		t.Fatalf("missing dependency: %v", err)
	}

	fakeTool(t, directory, "tesseract", "printf 'Recognized text'")

	d, err := Extract(context.Background(), filename, "image.PNG", Options{})
	if err != nil || d.Chunks[0].Text != "Recognized text" || len(d.Issues) == 0 {
		t.Fatalf("bad image OCR: %#v %v", d, err)
	}

	fakeTool(t, directory, "tesseract", "printf ' '")

	if _, err := Extract(context.Background(), filename, "image.png", Options{}); err == nil {
		t.Fatal("accepted empty OCR")
	}

	fakeTool(t, directory, "pdftotext", "printf 'First page\\f\\f'")
	fakeTool(t, directory, "pdftoppm", "exit 0")
	fakeTool(t, directory, "tesseract", "printf 'Scanned page'")

	d, err = Extract(context.Background(), filename, "report.pdf", Options{})
	if err != nil || len(d.Chunks) != 2 || d.Chunks[1].Text != "Scanned page" || d.Chunks[1].Location["page"] != 2 {
		t.Fatalf("bad PDF OCR: %#v %v", d, err)
	}
}
