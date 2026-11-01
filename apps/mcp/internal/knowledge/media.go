package knowledge

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

func image(ctx context.Context, path, name string) (Document, error) {
	d := newDocument()

	if _, err := exec.LookPath("tesseract"); err != nil {
		return d, fmt.Errorf("image extraction requires tesseract (OCR): %w", err)
	}

	output, err := command(ctx, []string{"tesseract", path, "stdout"}, nil)
	if err != nil {
		return d, err
	}

	d.chunk(string(output), map[string]any{"image": name})

	if len(d.Chunks) == 0 {
		return d, fmt.Errorf("no image text extracted; OCR found no readable text")
	}

	d.Issues = append(d.Issues, "Image uses OCR; verify recognition against the original. Visual content is not described.")

	return d, nil
}

func ocrPage(ctx context.Context, path string, page int) (string, error) {
	temporary, err := os.MkdirTemp("", "aero-ocr-")
	if err != nil {
		return "", err
	}
	defer func() { _ = os.RemoveAll(temporary) }()

	imagePath := filepath.Join(temporary, "page")

	_, err = command(ctx, []string{"pdftoppm", "-f", strconv.Itoa(page), "-singlefile", "-scale-to", "2000", "-png", path, imagePath}, nil)
	if err != nil {
		return "", err
	}

	output, err := command(ctx, []string{"tesseract", imagePath + ".png", "stdout"}, nil)

	return string(output), err
}

func pdf(ctx context.Context, path, _ string) (Document, error) {
	d := newDocument()

	if _, err := exec.LookPath("pdftotext"); err != nil {
		return d, fmt.Errorf("PDF extraction requires pdftotext (Poppler): %w", err)
	}

	output, err := command(ctx, []string{"pdftotext", "-layout", path, "-"}, nil)
	if err != nil {
		return d, err
	}

	pages := strings.Split(string(output), "\f")
	if strings.TrimSpace(pages[len(pages)-1]) == "" {
		pages = pages[:len(pages)-1]
	}

	_, renderErr := exec.LookPath("pdftoppm")
	_, ocrErr := exec.LookPath("tesseract")

	for i, page := range pages {
		if strings.TrimSpace(page) == "" && renderErr == nil && ocrErr == nil {
			page, err = ocrPage(ctx, path, i+1)
			if err != nil {
				d.Issues = append(d.Issues, fmt.Sprintf("Page %d OCR failed: %s", i+1, err))
			} else {
				d.Issues = append(d.Issues, fmt.Sprintf("Page %d uses OCR; verify uncertain recognition against the original.", i+1))
			}
		}

		d.chunk(page, map[string]any{"page": i + 1})
	}

	d.Issues = append(d.Issues, "Text extraction only; images, diagrams, and scanned pages require visual inspection/OCR.")
	if len(d.Chunks) == 0 {
		return d, fmt.Errorf("no PDF text extracted; OCR is required")
	}

	return d, nil
}
