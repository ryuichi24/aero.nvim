package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"reflect"
	"testing"
)

func TestHostReadRoutes(t *testing.T) {
	input := map[string]any{
		"epoch": "host", "target": "target", "worktree": "/workspace",
		"path": "/sources", "session": "session", "conversation": "conversation", "refresh": true,
	}

	for _, method := range []string{"reference_browse", "prompt_snippets", "submodule_browse"} {
		t.Run(method, func(t *testing.T) {
			for _, outcome := range []struct {
				name     string
				response hostResponse
				err      error
				status   int
				body     map[string]any
			}{
				{
					name: "success", status: http.StatusOK,
					response: hostResponse{Result: json.RawMessage(`{"items":[{"name":"Evidence"}],"ready":true}`)},
					body:     map[string]any{"items": []any{map[string]any{"name": "Evidence"}}, "ready": true},
				},
				{
					name: "host error", status: http.StatusBadRequest,
					response: hostResponse{Error: "scope is unavailable"},
					body:     map[string]any{"error": "scope is unavailable"},
				},
				{
					name: "transport error", status: http.StatusServiceUnavailable,
					err:  errors.New("internal connection details"),
					body: map[string]any{"error": "Neovim unavailable"},
				},
			} {
				t.Run(outcome.name, func(t *testing.T) {
					c := newClient(t, hostFunc(func(ctx context.Context, called string, params any) (hostResponse, error) {
						if ctx == nil || called != method {
							t.Errorf("unexpected host call: %s", called)
						}

						encoded, err := json.Marshal(params)
						if err != nil {
							t.Error(err)
						}

						var forwarded map[string]any
						if err := json.Unmarshal(encoded, &forwarded); err != nil {
							t.Error(err)
						}

						if !reflect.DeepEqual(forwarded, input) {
							t.Errorf("changed request: %s", encoded)
						}

						return outcome.response, outcome.err
					}))
					c.pair()

					body := c.json("POST", "/api/"+method, input, outcome.status)
					if !reflect.DeepEqual(body, outcome.body) {
						t.Fatalf("response = %#v, want %#v", body, outcome.body)
					}
				})
			}
		})
	}
}
