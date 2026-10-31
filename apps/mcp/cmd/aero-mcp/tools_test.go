package main

import (
	"context"
	"reflect"
	"testing"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

func TestToolsetDiscovery(t *testing.T) {
	for _, tc := range []struct {
		selection string
		want      []string
	}{
		{"reading", []string{"aero_reading_list_publish"}},
		{"knowledge", []string{"aero_knowledge"}},
		{"reports,reading,reports", []string{"aero_create_report", "aero_reading_list_publish"}},
		{"tasks", []string{"aero_create_ticket", "aero_get_board", "aero_get_ticket", "aero_list_boards", "aero_move_ticket", "aero_update_ticket_body", "aero_update_ticket_metadata"}},
	} {
		t.Run(tc.selection, func(t *testing.T) {
			selected, err := selectToolsets(tc.selection, false, false)
			if err != nil {
				t.Fatal(err)
			}

			server := mcp.NewServer(&mcp.Implementation{Name: "test", Version: "1"}, nil)

			for _, name := range selected {
				toolsetsByName[name](server, client{})
			}

			ctx := context.Background()
			st, ct := mcp.NewInMemoryTransports()

			ss, err := server.Connect(ctx, st, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer ss.Close()

			cs, err := mcp.NewClient(&mcp.Implementation{Name: "test", Version: "1"}, nil).Connect(ctx, ct, nil)
			if err != nil {
				t.Fatal(err)
			}
			defer cs.Close()

			result, err := cs.ListTools(ctx, nil)
			if err != nil {
				t.Fatal(err)
			}

			var got []string

			for _, tool := range result.Tools {
				got = append(got, tool.Name)
			}

			if !reflect.DeepEqual(got, tc.want) {
				t.Fatalf("tools = %v, want %v", got, tc.want)
			}
		})
	}
}

func TestToolsetValidation(t *testing.T) {
	for _, value := range []string{"unknown", "reading,", ",knowledge"} {
		if _, err := selectToolsets(value, false, false); err == nil {
			t.Fatalf("accepted %q", value)
		}
	}

	for _, flags := range [][2]bool{{true, true}, {true, false}, {false, true}} {
		if _, err := selectToolsets("reading", flags[0], flags[1]); err == nil {
			t.Fatal("accepted conflicting selectors")
		}
	}

	for _, tc := range []struct {
		reading, knowledge bool
		want               []string
	}{
		{false, false, []string{"tasks", "reports", "reading"}},
		{true, false, []string{"reading"}},
		{false, true, []string{"knowledge"}},
	} {
		got, err := selectToolsets("", tc.reading, tc.knowledge)
		if err != nil || !reflect.DeepEqual(got, tc.want) {
			t.Fatalf("selection = %v, %v", got, err)
		}
	}
}

func TestConnectionEnvironment(t *testing.T) {
	for _, name := range []string{"SOCKET", "CREDENTIAL"} {
		t.Setenv("AERO_TASK_"+name, "legacy")
		t.Setenv("AERO_MCP_"+name, "")

		if got := connectionEnv(name); got != "legacy" {
			t.Fatalf("fallback = %q", got)
		}

		t.Setenv("AERO_MCP_"+name, "shared")

		if got := connectionEnv(name); got != "shared" {
			t.Fatalf("preferred = %q", got)
		}
	}
}
