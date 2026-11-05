package main

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sync"
	"time"

	"github.com/modelcontextprotocol/go-sdk/mcp"
)

type Position struct {
	File     string `json:"file" jsonschema:"absolute path of the file open in vim"`
	Relative string `json:"relative,omitempty" jsonschema:"path relative to the directory vim was started in"`
	Line     int    `json:"line" jsonschema:"cursor line, 1-based"`
	Col      int    `json:"col" jsonschema:"cursor column, 1-based byte offset"`
	Visible  []int  `json:"visible,omitempty" jsonschema:"first and last line visible in the window"`
	Filetype string `json:"filetype,omitempty" jsonschema:"vim filetype of the buffer"`
	Modified bool   `json:"modified" jsonschema:"whether the buffer has unsaved changes, so the file on disk may differ"`
}

type Status struct {
	Cursor     Position `json:"cursor"`
	UpdatedAt  string   `json:"updated_at" jsonschema:"when vim last reported the position (RFC 3339)"`
	AgeSeconds float64  `json:"age_seconds" jsonschema:"seconds since vim last reported; a large value means vim may be idle or closed"`
}

type vimInfo struct {
	mu  sync.Mutex
	pos *Position
	at  time.Time
}

func (vi *vimInfo) set(p Position) {
	vi.mu.Lock()
	defer vi.mu.Unlock()
	vi.pos, vi.at = &p, time.Now()
}

func (vi *vimInfo) clear() {
	vi.mu.Lock()
	defer vi.mu.Unlock()
	vi.pos = nil
}

func (vi *vimInfo) get() (bool, Status) {
	vi.mu.Lock()
	defer vi.mu.Unlock()
	if vi.pos == nil {
		return false, Status{}
	}
	return true, Status{
		Cursor:     *vi.pos,
		UpdatedAt:  vi.at.Format(time.RFC3339),
		AgeSeconds: time.Since(vi.at).Round(time.Second).Seconds(),
	}
}

func (vi *vimInfo) AddToMux(m *http.ServeMux) {
	m.HandleFunc("/viminfo", func(w http.ResponseWriter, r *http.Request) {
		// Browsers always send Origin on cross-origin POSTs; vim and curl never do.
		// Rejecting it stops any open web page from spoofing the cursor position.
		if r.Header.Get("Origin") != "" {
			http.Error(w, "browser requests are not allowed", http.StatusForbidden)
			return
		}
		switch r.Method {
		case http.MethodPost:
			var p Position
			if err := json.NewDecoder(http.MaxBytesReader(w, r.Body, 64<<10)).Decode(&p); err != nil {
				http.Error(w, "bad JSON: "+err.Error(), http.StatusBadRequest)
				return
			}
			if p.File == "" || p.Line < 1 || p.Col < 1 {
				http.Error(w, "file, line and col are required; line and col start at 1", http.StatusBadRequest)
				return
			}
			vi.set(p)
			w.WriteHeader(http.StatusNoContent)
		case http.MethodDelete:
			vi.clear()
			w.WriteHeader(http.StatusNoContent)
		default:
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		}
	})
}

func (vi *vimInfo) AddToMCP(m *mcp.Server) {
	mcp.AddTool(
		m,
		&mcp.Tool{Name: "vim-info", Description: "Get the file open in the user's vim session and the cursor position in it. " +
			"Use it when the user refers to code by where they are in vim, e.g. \"the function I'm looking at in vim\" or \"the file I have open in vim\". " +
			"Only call it when the user mentions vim; \"this function\" or \"what am I looking at\" on their own don't mean vim. " +
			"If modified is true, the buffer has unsaved changes and the file on disk may not match what they see. " +
			"A large age_seconds means the position may be stale."},
		func(ctx context.Context, req *mcp.CallToolRequest, _ struct{}) (*mcp.CallToolResult, Status, error) {
			found, status := vi.get()
			if !found {
				return nil, status, errors.New("no vim position set")
			}
			return nil, status, nil
		},
	)
}
