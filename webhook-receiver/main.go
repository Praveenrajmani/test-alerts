package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
	"time"
)

const maxStored = 100

type receiver struct {
	alertCount atomic.Int64

	mu      sync.Mutex
	lastN   []json.RawMessage
}

func (r *receiver) handleAlerts(w http.ResponseWriter, req *http.Request) {
	body, err := io.ReadAll(req.Body)
	if err != nil {
		http.Error(w, "failed to read body", http.StatusBadRequest)
		return
	}
	defer req.Body.Close()

	entries := splitEntries(body)
	count := int64(len(entries))
	if count == 0 {
		count = 1
	}
	r.alertCount.Add(count)

	for _, entry := range entries {
		log.Printf("[ALERT] %s", truncate(string(entry), 500))
	}

	r.mu.Lock()
	for _, entry := range entries {
		r.lastN = append(r.lastN, entry)
		if len(r.lastN) > maxStored {
			r.lastN = r.lastN[len(r.lastN)-maxStored:]
		}
	}
	r.mu.Unlock()

	w.WriteHeader(http.StatusOK)
}

// splitEntries handles both single JSON objects and newline-delimited
// JSON (batch mode) that MinIO webhook targets may send.
func splitEntries(data []byte) []json.RawMessage {
	data = bytes.TrimSpace(data)
	if len(data) == 0 {
		return nil
	}

	var entries []json.RawMessage
	decoder := json.NewDecoder(bytes.NewReader(data))
	for decoder.More() {
		var raw json.RawMessage
		if err := decoder.Decode(&raw); err != nil {
			return []json.RawMessage{data}
		}
		entries = append(entries, raw)
	}
	if len(entries) == 0 {
		entries = append(entries, data)
	}
	return entries
}

func truncate(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[:n] + "..."
}

func (r *receiver) handleStats(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(map[string]any{
		"alerts_received": r.alertCount.Load(),
		"timestamp":       time.Now().UTC().Format(time.RFC3339),
	})
}

func (r *receiver) handleEntries(w http.ResponseWriter, _ *http.Request) {
	r.mu.Lock()
	defer r.mu.Unlock()

	w.Header().Set("Content-Type", "application/json")
	json.NewEncoder(w).Encode(r.lastN)
}

func (r *receiver) handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.WriteHeader(http.StatusOK)
	fmt.Fprintln(w, "ok")
}

func main() {
	port := os.Getenv("PORT")
	if port == "" {
		port = "9090"
	}

	r := &receiver{
		lastN: make([]json.RawMessage, 0),
	}

	mux := http.NewServeMux()
	mux.HandleFunc("/alerts", r.handleAlerts)
	mux.HandleFunc("/stats", r.handleStats)
	mux.HandleFunc("/entries", r.handleEntries)
	mux.HandleFunc("/health", r.handleHealth)

	log.Printf("Alert webhook receiver listening on :%s", port)
	log.Printf("  POST /alerts   - receive alert events")
	log.Printf("  GET  /stats    - received alert count")
	log.Printf("  GET  /entries  - last %d alert entries", maxStored)
	log.Printf("  GET  /health   - health check")
	log.Fatal(http.ListenAndServe(":"+port, mux))
}
