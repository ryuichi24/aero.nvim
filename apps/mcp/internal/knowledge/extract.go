// Package knowledge provides native extraction and language-independent adapters.
package knowledge

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/csv"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
	"unicode/utf8"
)

type Chunk struct {
	Text     string         `json:"text"`
	Location map[string]any `json:"location"`
	Vector   []float64      `json:"vector,omitempty"`
}

type Table struct {
	Name string     `json:"name"`
	Rows [][]string `json:"rows"`
}

type Document struct {
	Version        string   `json:"version,omitempty"`
	Chunks         []Chunk  `json:"chunks"`
	Tables         []Table  `json:"tables"`
	Issues         []string `json:"issues"`
	EmbeddingModel string   `json:"embedding_model,omitempty"`
}

type Adapter struct {
	Extensions []string `json:"extensions"`
	Command    []string `json:"command"`
}

type Options struct {
	Extractors       []Adapter `json:"extractors"`
	EmbeddingCommand []string  `json:"embedding_command"`
}

type extractor func(context.Context, string, string) (Document, error)

var builtins = map[string]extractor{
	".md": text, ".markdown": text, ".txt": text, ".csv": csvFile,
	".pdf": pdf, ".pptx": office, ".xlsx": office, ".docx": office,
	".png": image, ".jpg": image, ".jpeg": image, ".tif": image,
	".tiff": image, ".bmp": image, ".webp": image,
}

func newDocument() Document {
	return Document{Chunks: []Chunk{}, Tables: []Table{}, Issues: []string{}}
}

func (d *Document) chunk(text string, location map[string]any) {
	if strings.TrimSpace(text) != "" {
		d.Chunks = append(d.Chunks, Chunk{Text: text, Location: location})
	}
}

func command(ctx context.Context, argv []string, input []byte) ([]byte, error) {
	if len(argv) == 0 || argv[0] == "" {
		return nil, fmt.Errorf("adapter command must be a nonempty argv list")
	}

	ctx, cancel := context.WithTimeout(ctx, 120*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, argv[0], argv[1:]...)
	cmd.Stdin = bytes.NewReader(input)

	var stderr bytes.Buffer

	cmd.Stderr = &stderr

	output, err := cmd.Output()
	if err != nil {
		if ctx.Err() != nil {
			return nil, ctx.Err()
		}

		return output, fmt.Errorf("%s: %w: %s", argv[0], err, strings.TrimSpace(stderr.String()))
	}

	return output, nil
}

// Extract applies the same payload contract to native and custom extractors.
func Extract(ctx context.Context, path, name string, options Options) (Document, error) {
	var empty Document

	extension := strings.ToLower(filepath.Ext(name))

	var selected []string

	claimed := map[string]bool{}

	for _, adapter := range options.Extractors {
		if len(adapter.Extensions) == 0 || len(adapter.Command) == 0 {
			return empty, fmt.Errorf("extractor requires extensions and a command argv list")
		}

		for _, arg := range adapter.Command {
			if arg == "" {
				return empty, fmt.Errorf("extractor command arguments must be nonempty")
			}
		}

		for _, ext := range adapter.Extensions {
			if len(ext) < 2 || ext[0] != '.' || ext != strings.ToLower(ext) {
				return empty, fmt.Errorf("extractor extensions must be lowercase with a leading dot")
			}

			if claimed[ext] {
				return empty, fmt.Errorf("duplicate custom extractor: %s", ext)
			}

			claimed[ext] = true
			if ext == extension {
				selected = adapter.Command
			}
		}
	}

	f, err := os.Open(path)
	if err != nil {
		return empty, err
	}

	hash := sha256.New()
	_, err = io.Copy(hash, f)
	_ = f.Close()

	if err != nil {
		return empty, err
	}

	var document Document

	if selected != nil {
		absolute, absErr := filepath.Abs(path)
		if absErr != nil {
			return empty, absErr
		}

		request, marshalErr := json.Marshal(map[string]any{"protocol_version": 1, "path": absolute, "name": name, "extension": extension})
		if marshalErr != nil {
			return empty, marshalErr
		}

		output, runErr := command(ctx, selected, request)
		if runErr != nil {
			return empty, runErr
		}

		document, err = decodePayload(output)
		if err != nil {
			return empty, fmt.Errorf("invalid extractor JSON: %w", err)
		}
		// Identity and vectors are supplied by the runner, never by adapters.
		document.EmbeddingModel = ""
		for i := range document.Chunks {
			document.Chunks[i].Vector = nil
		}
	} else {
		adapter := builtins[extension]
		if adapter == nil {
			return empty, fmt.Errorf("Unsupported source format: %s", extension)
		}

		document, err = adapter(ctx, path, name)
		if err != nil {
			return empty, err
		}
	}

	if err = validate(document); err != nil {
		return empty, err
	}

	document.Version = hex.EncodeToString(hash.Sum(nil))
	if len(options.EmbeddingCommand) > 0 && len(document.Chunks) > 0 {
		if err = embed(ctx, &document, options.EmbeddingCommand); err != nil {
			document.Issues = append(document.Issues, "Semantic indexing unavailable: "+err.Error())
		}
	}

	return document, nil
}

func validate(d Document) error {
	if d.Chunks == nil || d.Tables == nil || d.Issues == nil {
		return fmt.Errorf("extractor requires chunks, tables, and issues arrays")
	}

	for _, chunk := range d.Chunks {
		if strings.TrimSpace(chunk.Text) == "" || chunk.Location == nil {
			return fmt.Errorf("extractor chunks require nonempty text and a location object")
		}

		for key, value := range chunk.Location {
			var number float64

			switch v := value.(type) {
			case string:
				if key == "line" || key == "end_line" || key == "page" || key == "slide" || key == "row" {
					return fmt.Errorf("positional locations must be positive integers")
				}

				continue
			case int:
				number = float64(v)
			case float64:
				number = v
			default:
				return fmt.Errorf("locations require string or numeric values")
			}

			if math.IsNaN(number) || math.IsInf(number, 0) {
				return fmt.Errorf("locations must be finite")
			}

			if key == "line" || key == "end_line" || key == "page" || key == "slide" || key == "row" {
				if number < 1 || number != math.Trunc(number) {
					return fmt.Errorf("positional locations must be positive integers")
				}
			}
		}
	}

	for _, table := range d.Tables {
		if table.Rows == nil {
			return fmt.Errorf("extractor tables require rows arrays")
		}

		for _, row := range table.Rows {
			if row == nil {
				return fmt.Errorf("extractor table rows must be arrays")
			}
		}
	}

	return nil
}

func decodePayload(output []byte) (Document, error) {
	var d Document
	if err := json.Unmarshal(output, &d); err != nil {
		return d, err
	}
	// encoding/json accepts null into string fields; explicitly reject those
	// wire values so every language observes the same adapter contract.
	var wire struct {
		Issues []*string `json:"issues"`
		Tables []struct {
			Name *string     `json:"name"`
			Rows [][]*string `json:"rows"`
		} `json:"tables"`
	}
	if err := json.Unmarshal(output, &wire); err != nil {
		return d, err
	}

	for _, issue := range wire.Issues {
		if issue == nil {
			return d, fmt.Errorf("extractor issues must be strings")
		}
	}

	for _, table := range wire.Tables {
		if table.Name == nil {
			return d, fmt.Errorf("extractor tables require a name")
		}

		for _, row := range table.Rows {
			for _, cell := range row {
				if cell == nil {
					return d, fmt.Errorf("extractor table cells must be strings")
				}
			}
		}
	}

	return d, validate(d)
}

func embed(ctx context.Context, d *Document, argv []string) error {
	texts := make([]string, len(d.Chunks))
	for i, chunk := range d.Chunks {
		texts[i] = chunk.Text
	}

	input, err := json.Marshal(map[string]any{"texts": texts})
	if err != nil {
		return err
	}

	output, err := command(ctx, argv, input)
	if err != nil {
		return err
	}

	var result struct {
		Model   string      `json:"model"`
		Vectors [][]float64 `json:"vectors"`
	}
	if err = json.Unmarshal(output, &result); err != nil {
		return err
	}

	if result.Model == "" || len(result.Vectors) != len(texts) || len(result.Vectors[0]) == 0 {
		return fmt.Errorf("invalid embedding model/vectors")
	}

	dimension := len(result.Vectors[0])
	for _, vector := range result.Vectors {
		if len(vector) != dimension {
			return fmt.Errorf("embedding dimensions differ")
		}

		for _, value := range vector {
			if math.IsNaN(value) || math.IsInf(value, 0) {
				return fmt.Errorf("embedding vectors must be finite")
			}
		}
	}

	d.EmbeddingModel = result.Model
	for i, vector := range result.Vectors {
		d.Chunks[i].Vector = vector
	}

	return nil
}

func utf8Text(path string) (string, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return "", err
	}

	if !utf8.Valid(raw) {
		return "", fmt.Errorf("source is not valid UTF-8")
	}

	return strings.TrimPrefix(string(raw), "\ufeff"), nil
}

func text(_ context.Context, path, _ string) (Document, error) {
	d := newDocument()

	content, err := utf8Text(path)
	if err != nil {
		return d, err
	}

	content = strings.ReplaceAll(strings.ReplaceAll(content, "\r\n", "\n"), "\r", "\n")
	lines := strings.Split(strings.TrimSuffix(content, "\n"), "\n")
	heading := ""

	for start := 0; start < len(lines); start += 30 {
		end := min(start+30, len(lines))
		for _, line := range lines[start:end] {
			if strings.HasPrefix(line, "#") {
				heading = strings.TrimLeft(line, "# ")
			}
		}

		d.chunk(strings.Join(lines[start:end], "\n"), map[string]any{"line": start + 1, "end_line": end, "heading": heading})
	}

	return d, nil
}

func csvFile(_ context.Context, path, name string) (Document, error) {
	d := newDocument()

	content, err := utf8Text(path)
	if err != nil {
		return d, err
	}

	reader := csv.NewReader(strings.NewReader(content))
	reader.FieldsPerRecord = -1

	rows, err := reader.ReadAll()
	if err != nil {
		return d, err
	}

	if rows == nil {
		rows = [][]string{}
	}

	d.Tables = append(d.Tables, Table{Name: name, Rows: rows})
	for i, row := range rows {
		encoded, marshalErr := json.Marshal(row)
		if marshalErr != nil {
			return d, marshalErr
		}

		d.chunk(string(encoded), map[string]any{"row": i + 1, "table": name})
	}

	return d, nil
}
