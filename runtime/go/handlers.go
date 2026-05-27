package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"strings"

	"github.com/theashbhat/LoopHarness/runtime/go/agent"
	"github.com/theashbhat/LoopHarness/runtime/go/bridge"
	"github.com/theashbhat/LoopHarness/runtime/go/storage"
)

func authMiddleware(secret string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		auth := r.Header.Get("Authorization")
		if !strings.HasPrefix(auth, "Bearer ") || strings.TrimPrefix(auth, "Bearer ") != secret {
			http.Error(w, `{"error":"unauthorized"}`, http.StatusUnauthorized)
			return
		}
		next(w, r)
	}
}

// POST /turn
func handleTurn(ag *agent.Agent, store *storage.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			Messages       []agent.Message `json:"messages"`
			ConversationID string          `json:"conversation_id"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadRequest)
			return
		}
		if len(req.Messages) == 0 {
			http.Error(w, `{"error":"messages required"}`, http.StatusBadRequest)
			return
		}

		// Stream response via SSE
		w.Header().Set("Content-Type", "text/event-stream")
		w.Header().Set("Cache-Control", "no-cache")
		w.Header().Set("Connection", "keep-alive")
		flusher, ok := w.(http.Flusher)
		if !ok {
			http.Error(w, `{"error":"streaming not supported"}`, http.StatusInternalServerError)
			return
		}

		turnID, err := ag.RunTurn(r.Context(), req.Messages, req.ConversationID, func(token string) {
			fmt.Fprintf(w, "data: %s\n\n", token)
			flusher.Flush()
		})
		if err != nil {
			fmt.Fprintf(w, "event: error\ndata: %s\n\n", err.Error())
			flusher.Flush()
			return
		}
		fmt.Fprintf(w, "event: done\ndata: {\"turn_id\":%q}\n\n", turnID)
		flusher.Flush()
	}
}

// POST /result
func handleResult(brg *bridge.Bridge) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		var req struct {
			JobID  string          `json:"job_id"`
			Result json.RawMessage `json:"result"`
			Error  string          `json:"error"`
		}
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusBadRequest)
			return
		}
		if req.JobID == "" {
			http.Error(w, `{"error":"job_id required"}`, http.StatusBadRequest)
			return
		}

		brg.ResolveResult(req.JobID, bridge.Result{
			Data:  req.Result,
			Error: req.Error,
		})
		w.Header().Set("Content-Type", "application/json")
		w.Write([]byte(`{"ok":true}`))
	}
}

// GET /turn/{id}
func handleGetTurn(store *storage.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		id := r.PathValue("id")
		turn, err := store.GetTurn(id)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(turn)
	}
}

// GET /job/{job_id}
func handleGetJob(store *storage.Store) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		jobID := r.PathValue("job_id")
		job, err := store.GetJob(jobID)
		if err != nil {
			http.Error(w, fmt.Sprintf(`{"error":%q}`, err.Error()), http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		json.NewEncoder(w).Encode(job)
	}
}
