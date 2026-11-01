package knowledge

import (
	"archive/zip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

const officeLimit = 128 * 1024 * 1024

type officeNode struct {
	Path       string         `json:"path"`
	Type       string         `json:"type"`
	Text       string         `json:"text"`
	Preview    string         `json:"preview"`
	ChildCount int            `json:"childCount"`
	Format     map[string]any `json:"format"`
	Children   []officeNode   `json:"children"`
}

func officeNodes(ctx context.Context, filename, verb, path string) ([]officeNode, []string, error) {
	argv := []string{"officecli", verb, filename, path, "--json"}
	if verb == "get" {
		argv = append(argv, "--depth", "100")
	}

	output, runErr := command(ctx, argv, nil)
	if runErr != nil {
		var exit *exec.ExitError
		if !errors.As(runErr, &exit) || exit.ExitCode() != 2 {
			return nil, nil, runErr
		}
	}

	var response struct {
		Success bool `json:"success"`
		Data    struct {
			Results []officeNode `json:"results"`
		} `json:"data"`
		Warnings []json.RawMessage `json:"warnings"`
		Error    json.RawMessage   `json:"error"`
	}
	if err := json.Unmarshal(output, &response); err != nil {
		return nil, nil, fmt.Errorf("invalid officecli JSON: %w", err)
	}

	if !response.Success {
		return nil, nil, fmt.Errorf("officecli extraction failed: %s", response.Error)
	}

	if response.Data.Results == nil {
		return nil, nil, fmt.Errorf("officecli response is missing data.results")
	}

	issues := []string{}

	for _, warning := range response.Warnings {
		var text string
		if json.Unmarshal(warning, &text) != nil {
			text = string(warning)
		}

		issues = append(issues, "officecli: "+text)
	}

	return response.Data.Results, issues, nil
}

// officecli detects formats by suffix, while managed source paths have none.
// Work on a temporary copy so extraction never mutates the managed source.
func officeCopy(filename, extension string) (string, func(), error) {
	archive, err := zip.OpenReader(filename)
	if err != nil {
		return "", nil, err
	}

	var total uint64

	for _, file := range archive.File {
		if file.UncompressedSize64 > officeLimit || total > officeLimit-file.UncompressedSize64 {
			_ = archive.Close()
			return "", nil, fmt.Errorf("expanded Office document exceeds 128 MiB extraction limit")
		}

		total += file.UncompressedSize64
	}

	_ = archive.Close()

	directory, err := os.MkdirTemp("", "aero-office-")
	if err != nil {
		return "", nil, err
	}

	cleanup := func() { _ = os.RemoveAll(directory) }

	source, err := os.Open(filename)
	if err != nil {
		cleanup()
		return "", nil, err
	}
	defer source.Close()

	target := filepath.Join(directory, "source"+extension)

	destination, err := os.OpenFile(target, os.O_CREATE|os.O_WRONLY|os.O_EXCL, 0o600)
	if err != nil {
		cleanup()
		return "", nil, err
	}

	_, copyErr := io.Copy(destination, source)

	closeErr := destination.Close()
	if err := errors.Join(copyErr, closeErr); err != nil {
		cleanup()
		return "", nil, err
	}

	return target, cleanup, nil
}

func office(ctx context.Context, filename, name string) (Document, error) {
	d := newDocument()

	if _, err := exec.LookPath("officecli"); err != nil {
		return d, fmt.Errorf("Office extraction requires officecli on PATH: %w", err)
	}

	extension := strings.ToLower(filepath.Ext(name))

	copyPath, cleanup, err := officeCopy(filename, extension)
	if err != nil {
		return d, err
	}
	defer cleanup()

	root := "/"

	if extension == ".docx" {
		root = "/body"
	}

	nodes, issues, err := officeNodes(ctx, copyPath, "get", root)
	if err != nil {
		return d, err
	}

	d.Issues = append(d.Issues, issues...)

	for _, node := range nodes {
		if extension == ".xlsx" {
			if err := officeSheets(&d, node); err != nil {
				return d, err
			}
		} else {
			officeText(&d, node, extension)
		}
	}

	if extension == ".pptx" {
		notes, warnings, err := officeNodes(ctx, copyPath, "query", "notes")
		if err != nil {
			return d, err
		}

		d.Issues = append(d.Issues, warnings...)

		for _, note := range notes {
			officeText(&d, note, extension)
		}

		d.Issues = append(d.Issues, "OfficeCLI extracted slide text, tables, and speaker notes; images, charts, and diagrams are not visually interpreted.")
	} else if extension == ".docx" {
		d.Issues = append(d.Issues, "OfficeCLI extracted Word body text and tables; headers, footers, comments, and visual content are not included. Page numbers are not inferred.")
	} else {
		d.Issues = append(d.Issues, "OfficeCLI extracted worksheet values; formula evaluation is limited to OfficeCLI's supported functions. Charts/images are not visually interpreted.")
	}

	return d, nil
}

func officeLocation(node officeNode, extension string) map[string]any {
	location := map[string]any{"path": node.Path}
	if extension == ".pptx" && strings.HasPrefix(node.Path, "/slide[") {
		if end := strings.IndexByte(node.Path, ']'); end > 7 {
			if slide, err := strconv.Atoi(node.Path[7:end]); err == nil && slide > 0 {
				location["slide"] = slide
			}
		}
	}

	return location
}

func officeText(d *Document, node officeNode, extension string) {
	if node.ChildCount > len(node.Children) {
		d.Issues = append(d.Issues, "OfficeCLI returned incomplete children at "+node.Path)
	}

	if node.Type == "table" {
		rows := [][]string{}

		for _, row := range node.Children {
			if row.Type != "row" && row.Type != "tr" {
				continue
			}

			values := []string{}

			for _, cell := range row.Children {
				if cell.Type == "cell" || cell.Type == "tc" {
					values = append(values, cell.Text)
				}
			}

			rows = append(rows, values)

			encoded, err := json.Marshal(values)
			if err == nil {
				location := officeLocation(row, extension)
				location["table"], location["row"] = node.Path, len(rows)
				d.chunk(string(encoded), location)
			}
		}

		d.Tables = append(d.Tables, Table{Name: node.Path, Rows: rows})

		return
	}

	if node.Type == "paragraph" || node.Type == "notes" || (len(node.Children) == 0 && node.Text != "") {
		d.chunk(node.Text, officeLocation(node, extension))
		return
	}

	for _, child := range node.Children {
		officeText(d, child, extension)
	}
}

func officeSheets(d *Document, node officeNode) error {
	if node.Type != "sheet" {
		for _, child := range node.Children {
			if err := officeSheets(d, child); err != nil {
				return err
			}
		}

		return nil
	}

	name := strings.TrimPrefix(node.Path, "/")
	rows := [][]string{}

	var visit func(officeNode) error

	visit = func(item officeNode) error {
		if item.ChildCount > len(item.Children) {
			d.Issues = append(d.Issues, "OfficeCLI returned incomplete children at "+item.Path)
		}

		if item.Type == "cell" {
			address := item.Path[strings.LastIndex(item.Path, "/")+1:]

			column, offset := 0, 0
			for offset < len(address) && address[offset] >= 'A' && address[offset] <= 'Z' {
				column = column*26 + int(address[offset]-'A') + 1
				if column > 16384 {
					return fmt.Errorf("invalid OfficeCLI cell address: %s", item.Path)
				}

				offset++
			}

			row, err := strconv.Atoi(address[offset:])
			if err != nil || row < 1 || row > 1048576 || column < 1 {
				return fmt.Errorf("invalid OfficeCLI cell address: %s", item.Path)
			}

			for len(rows) < row {
				rows = append(rows, []string{})
			}

			for len(rows[row-1]) < column {
				rows[row-1] = append(rows[row-1], "")
			}

			value := item.Text
			if formula, _ := item.Format["formula"].(string); formula != "" {
				computed, hasComputed := item.Format["computedValue"].(string)

				cached, hasCached := item.Format["cachedValue"].(string)
				switch {
				case hasComputed:
					value = computed
					if hasCached && computed != cached {
						d.Issues = append(d.Issues, "Formula cache differs from OfficeCLI evaluation at "+item.Path)
					}
				case hasCached:
					value = cached

					d.Issues = append(d.Issues, "Formula uses a potentially stale cached value at "+item.Path)
				default:
					value = ""

					d.Issues = append(d.Issues, "Formula has no evaluated value at "+item.Path+": "+formula)
				}
			}

			rows[row-1][column-1] = value

			return nil
		}

		for _, child := range item.Children {
			if err := visit(child); err != nil {
				return err
			}
		}

		return nil
	}
	if err := visit(node); err != nil {
		return err
	}

	d.Tables = append(d.Tables, Table{Name: name, Rows: rows})
	for i, row := range rows {
		if len(row) == 0 {
			continue
		}

		encoded, err := json.Marshal(row)
		if err != nil {
			return err
		}

		d.chunk(string(encoded), map[string]any{"sheet": name, "row": i + 1})
	}

	return nil
}
