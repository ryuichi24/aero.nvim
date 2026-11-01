package knowledge

import (
	"context"
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"strings"
	"testing"
)

func TestOfficeStructuredEvidence(t *testing.T) {
	d := newDocument()

	var sheet officeNode
	if err := json.Unmarshal([]byte(`{"type":"sheet","path":"/Revenue","children":[
		{"type":"cell","path":"/Revenue/C3","text":"123"},
		{"type":"cell","path":"/Revenue/D3","text":"stale","format":{"formula":"C3*2","cachedValue":"200","computedValue":"246"}},
		{"type":"cell","path":"/Revenue/E3","text":"#OCLI_NOTEVAL!","format":{"formula":"UNSUPPORTED()","evaluated":false}}
	]}`), &sheet); err != nil {
		t.Fatal(err)
	}

	if err := officeSheets(&d, sheet); err != nil {
		t.Fatal(err)
	}

	if !reflect.DeepEqual(d.Tables[0].Rows, [][]string{{}, {}, {"", "", "123", "246", ""}}) || d.Chunks[0].Location["row"] != 3 || len(d.Issues) != 2 {
		t.Fatalf("bad spreadsheet: %#v", d)
	}

	var table officeNode
	if err := json.Unmarshal([]byte(`{"type":"table","path":"/body/tbl[1]","children":[{"type":"row","path":"/body/tbl[1]/tr[1]","children":[{"type":"cell","text":"Revenue"},{"type":"cell","text":"123"}]}]}`), &table); err != nil {
		t.Fatal(err)
	}

	d = newDocument()
	officeText(&d, table, ".docx")

	if len(d.Chunks) != 1 || !reflect.DeepEqual(d.Tables[0].Rows, [][]string{{"Revenue", "123"}}) {
		t.Fatalf("bad Word table: %#v", d)
	}

	officeText(&d, officeNode{Type: "paragraph", Path: "/slide[10]/shape[1]/paragraph[1]", Text: "Slide evidence", Children: []officeNode{{Type: "run", Text: "Slide evidence"}}}, ".pptx")

	if len(d.Chunks) != 2 || d.Chunks[1].Location["slide"] != 10 {
		t.Fatalf("duplicated slide text or missing location: %#v", d)
	}
}

func TestOfficeCLIProtocol(t *testing.T) {
	directory := t.TempDir()
	t.Setenv("PATH", directory)

	filename := officeSource(t, map[string]string{"test.xml": "<test/>"})
	if _, err := Extract(context.Background(), filename, "report.docx", Options{}); err == nil || !strings.Contains(err.Error(), "requires officecli") {
		t.Fatalf("missing dependency: %v", err)
	}
	// Verify suffix restoration, JSON arguments, exit-2 caveats, and source isolation.
	fakeTool(t, directory, "officecli", `case "$2" in *.docx) ;; *) exit 5;; esac
test "$1" = get && test "$3" = /body && test "$4" = --json || exit 6
printf 'changed temporary copy' > "$2"
printf '%s' '{"success":true,"warnings":["Partial coverage"],"data":{"results":[{"type":"body","path":"/body","children":[{"type":"paragraph","path":"/body/p[1]","text":"Word evidence"}]}]}}'
exit 2`)

	before, err := os.ReadFile(filename)
	if err != nil {
		t.Fatal(err)
	}

	d, err := Extract(context.Background(), filename, "report.DOCX", Options{})
	if err != nil || len(d.Chunks) != 1 || d.Chunks[0].Text != "Word evidence" || len(d.Issues) < 2 {
		t.Fatalf("bad officecli result: %#v %v", d, err)
	}

	after, err := os.ReadFile(filename)
	if err != nil || string(before) != string(after) {
		t.Fatal("managed source was modified")
	}

	for _, response := range []string{`{"success":false,"error":{"message":"failed"}}`, `{"success":true}`, `not JSON`} {
		fakeTool(t, directory, "officecli", "printf '%s' '"+response+"'")

		if _, err := Extract(context.Background(), filename, "report.docx", Options{}); err == nil {
			t.Fatalf("accepted bad officecli response: %s", response)
		}
	}
}

func TestOfficeCLIIntegration(t *testing.T) {
	if _, err := exec.LookPath("officecli"); err != nil {
		t.Skip("officecli is not installed")
	}

	ctx := context.Background()
	run := func(args ...string) {
		t.Helper()

		if output, err := command(ctx, append([]string{"officecli"}, args...), nil); err != nil {
			t.Fatalf("officecli %v: %v %s", args, err, output)
		}
	}
	directory := t.TempDir()

	for _, extension := range []string{".docx", ".pptx", ".xlsx"} {
		t.Run(extension, func(t *testing.T) {
			filename := filepath.Join(directory, "fixture"+extension)
			run("create", filename)

			switch extension {
			case ".docx":
				run("add", filename, "/body", "--type", "paragraph", "--prop", "text=Word evidence")
				run("add", filename, "/body", "--type", "table", "--prop", "rows=1", "--prop", "cols=2")
				run("set", filename, "/body/tbl[1]/tr[1]", "--prop", "c1=Revenue", "--prop", "c2=123")
			case ".pptx":
				run("add", filename, "/", "--type", "slide", "--prop", "layout=blank")
				run("add", filename, "/slide[1]", "--type", "shape", "--prop", "text=Slide evidence")
				run("add", filename, "/slide[1]", "--type", "notes", "--prop", "text=Speaker evidence")
				run("add", filename, "/slide[1]", "--type", "table", "--prop", "rows=1", "--prop", "cols=2")
				run("set", filename, "/slide[1]/table[1]/tr[1]", "--prop", "c1=Revenue", "--prop", "c2=123")
			case ".xlsx":
				run("set", filename, "/Sheet1/C3", "--prop", "value=123")
				run("set", filename, "/Sheet1/D3", "--prop", "formula=C3*2")
			}

			run("save", filename)

			d, err := Extract(ctx, filename, "original"+extension, Options{})
			if err != nil {
				t.Fatal(err)
			}

			if len(d.Chunks) == 0 || len(d.Issues) == 0 {
				t.Fatalf("missing Office evidence: %#v", d)
			}

			switch extension {
			case ".docx":
				if d.Chunks[0].Text != "Word evidence" || len(d.Tables) != 1 {
					t.Fatalf("bad Word evidence: %#v", d)
				}
			case ".pptx":
				if len(d.Chunks) != 3 || d.Chunks[0].Location["slide"] != 1 || d.Chunks[2].Text != "Speaker evidence" || len(d.Tables) != 1 || !reflect.DeepEqual(d.Tables[0].Rows, [][]string{{"Revenue", "123"}}) {
					t.Fatalf("bad slide evidence: %#v", d)
				}
			case ".xlsx":
				if !reflect.DeepEqual(d.Tables[0].Rows, [][]string{{}, {}, {"", "", "123", "246"}}) {
					t.Fatalf("bad Excel evidence: %#v", d)
				}
			}
		})
	}
}
