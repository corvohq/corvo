package server

import (
	"net/http"

	"github.com/go-chi/chi/v5"
	"github.com/user/corvo/internal/store"
)

func (s *Server) handleAddScore(w http.ResponseWriter, r *http.Request) {
	var req store.AddScoreRequest
	if err := decodeJSON(r, &req); err != nil {
		writeError(w, http.StatusBadRequest, "invalid JSON", "PARSE_ERROR")
		return
	}
	out, err := s.store.AddScore(req)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "SCORE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleListJobScores(w http.ResponseWriter, r *http.Request) {
	jobID := chi.URLParam(r, "id")
	out, err := s.store.ListJobScores(jobID)
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "SCORE_ERROR")
		return
	}
	if out == nil {
		out = []store.JobScore{}
	}
	writeJSON(w, http.StatusOK, map[string]any{"scores": out})
}

func (s *Server) handleScoreSummary(w http.ResponseWriter, r *http.Request) {
	queue := r.URL.Query().Get("queue")
	period := r.URL.Query().Get("period")
	out, err := s.store.ScoreSummary(store.ScoreSummaryRequest{Queue: queue, Period: period})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "SCORE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, out)
}

func (s *Server) handleScoreCompare(w http.ResponseWriter, r *http.Request) {
	queue := r.URL.Query().Get("queue")
	period := r.URL.Query().Get("period")
	groupBy := r.URL.Query().Get("group_by")
	out, err := s.store.ScoreCompare(store.ScoreCompareRequest{
		Queue:   queue,
		Period:  period,
		GroupBy: groupBy,
	})
	if err != nil {
		writeError(w, http.StatusBadRequest, err.Error(), "SCORE_ERROR")
		return
	}
	writeJSON(w, http.StatusOK, out)
}
