package server

import (
	"context"
	"encoding/json"
	"errors"
	"log/slog"
	"net/http"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

const (
	defaultWorkDuration = 200 * time.Millisecond
	maximumWorkDuration = 2 * time.Second
)

var errInvalidWorkDuration = errors.New("duration_ms must be between 1 and 2000")

type cpuWorkOutcome string

const (
	cpuWorkCompleted cpuWorkOutcome = "completed"
	cpuWorkRejected  cpuWorkOutcome = "rejected"
	cpuWorkCancelled cpuWorkOutcome = "cancelled"
)

type Server struct {
	logger  *slog.Logger
	metrics *cpuWorkMetrics
	mux     *http.ServeMux
}

type cpuWorkMetrics struct {
	duration *prometheus.HistogramVec
	requests *prometheus.CounterVec
}

type alertPayload struct {
	Status string `json:"status"`
	Alerts []struct {
		Labels map[string]string `json:"labels"`
	} `json:"alerts"`
}

func New(logger *slog.Logger) *Server {
	metrics, registry := newCPUWorkMetrics()
	server := &Server{logger: logger, metrics: metrics, mux: http.NewServeMux()}
	server.mux.HandleFunc("GET /healthz", server.handleHealth)
	server.mux.Handle("GET /metrics", promhttp.HandlerFor(registry, promhttp.HandlerOpts{}))
	server.mux.HandleFunc("/cpu-work", server.handleCPUWork)
	server.mux.HandleFunc("POST /alerts", server.handleAlerts)
	return server
}

func (s *Server) Handler() http.Handler {
	return s.mux
}

func (s *Server) handleHealth(writer http.ResponseWriter, _ *http.Request) {
	writeText(writer, http.StatusOK, "ok\n")
}

func (s *Server) handleCPUWork(writer http.ResponseWriter, request *http.Request) {
	startedAt := time.Now()
	outcome := cpuWorkRejected
	defer func() {
		s.metrics.observe(outcome, time.Since(startedAt))
	}()

	if request.Method != http.MethodGet {
		writer.Header().Set("Allow", http.MethodGet)
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	duration, err := workDuration(request)
	if err != nil {
		http.Error(writer, err.Error(), http.StatusBadRequest)
		return
	}

	if !spinUntil(request.Context(), duration) {
		outcome = cpuWorkCancelled
		http.Error(writer, "request cancelled", http.StatusRequestTimeout)
		return
	}

	outcome = cpuWorkCompleted
	writeJSON(writer, http.StatusOK, map[string]string{"status": "completed"})
}

func newCPUWorkMetrics() (*cpuWorkMetrics, *prometheus.Registry) {
	metrics := &cpuWorkMetrics{
		requests: prometheus.NewCounterVec(prometheus.CounterOpts{
			Name: "cpu_work_requests_total",
			Help: "CPU-work requests grouped by HTTP outcome.",
		}, []string{"outcome"}),
		duration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "cpu_work_request_duration_seconds",
			Help:    "CPU-work request duration grouped by HTTP outcome.",
			Buckets: []float64{0.001, 0.005, 0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10},
		}, []string{"outcome"}),
	}
	registry := prometheus.NewRegistry()
	registry.MustRegister(metrics.requests, metrics.duration)
	return metrics, registry
}

func (metrics *cpuWorkMetrics) observe(outcome cpuWorkOutcome, duration time.Duration) {
	labels := prometheus.Labels{"outcome": string(outcome)}
	metrics.requests.With(labels).Inc()
	metrics.duration.With(labels).Observe(duration.Seconds())
}

func (s *Server) handleAlerts(writer http.ResponseWriter, request *http.Request) {
	defer func() {
		if err := request.Body.Close(); err != nil {
			s.logger.Debug("request body close failed", slog.Any("error", err))
		}
	}()
	request.Body = http.MaxBytesReader(writer, request.Body, 1<<20)

	var payload alertPayload
	if err := json.NewDecoder(request.Body).Decode(&payload); err != nil {
		http.Error(writer, "invalid alert payload", http.StatusBadRequest)
		return
	}

	alertNames := make([]string, 0, len(payload.Alerts))
	for _, alert := range payload.Alerts {
		if name := alert.Labels["alertname"]; name != "" {
			alertNames = append(alertNames, name)
		}
	}
	sort.Strings(alertNames)
	s.logger.Info("alert notification received", slog.String("status", payload.Status), slog.Int("alert_count", len(payload.Alerts)), slog.String("alert_names", strings.Join(alertNames, ",")))
	writeJSON(writer, http.StatusAccepted, map[string]string{"status": "accepted"})
}

func workDuration(request *http.Request) (time.Duration, error) {
	rawDuration := request.URL.Query().Get("duration_ms")
	if rawDuration == "" {
		return defaultWorkDuration, nil
	}

	milliseconds, err := strconv.Atoi(rawDuration)
	if err != nil || milliseconds < 1 || milliseconds > int(maximumWorkDuration/time.Millisecond) {
		return 0, errInvalidWorkDuration
	}
	return time.Duration(milliseconds) * time.Millisecond, nil
}

func spinUntil(ctx context.Context, duration time.Duration) bool {
	deadline := time.Now().Add(duration)
	value := uint64(1)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return false
		default:
			value = value*1_664_525 + 1_013_904_223
		}
	}
	runtime.KeepAlive(value)
	return true
}

func writeText(writer http.ResponseWriter, status int, body string) {
	writer.WriteHeader(status)
	if _, err := writer.Write([]byte(body)); err != nil {
		slog.Debug("response write failed", slog.Any("error", err))
	}
}

func writeJSON(writer http.ResponseWriter, status int, value map[string]string) {
	writer.Header().Set("Content-Type", "application/json")
	writer.WriteHeader(status)
	if err := json.NewEncoder(writer).Encode(value); err != nil {
		slog.Debug("response encode failed", slog.Any("error", err))
	}
}
