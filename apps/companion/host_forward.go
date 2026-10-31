package main

import "net/http"

// forwardHostRead forwards decoded input; routes retain their request schemas.
func (b *bridge) forwardHostRead(w http.ResponseWriter, r *http.Request, method string, input any) {
	response, err := b.state.host.Call(r.Context(), method, input)
	if err != nil {
		reject(w, http.StatusServiceUnavailable, "Neovim unavailable")
		return
	}

	if response.Error != "" {
		reject(w, http.StatusBadRequest, response.Error)
		return
	}

	reply(w, http.StatusOK, response.Result)
}
