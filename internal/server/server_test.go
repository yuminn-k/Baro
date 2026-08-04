package server

import (
	"bytes"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestServer_returnsHealthy_when_healthzIsRequested(t *testing.T) {
	// Given
	server := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/healthz", nil)

	// When
	server.Handler().ServeHTTP(recorder, request)

	// Then
	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusOK)
	}
	if body := recorder.Body.String(); body != "ok\n" {
		t.Fatalf("body = %q, want %q", body, "ok\\n")
	}
}

func TestServer_recordsCPUWorkMetric_when_workIsRequested(t *testing.T) {
	// Given
	server := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	workRecorder := httptest.NewRecorder()
	workRequest := httptest.NewRequest(http.MethodGet, "/cpu-work?duration_ms=1", nil)

	// When
	server.Handler().ServeHTTP(workRecorder, workRequest)
	metricsRecorder := httptest.NewRecorder()
	metricsRequest := httptest.NewRequest(http.MethodGet, "/metrics", nil)
	server.Handler().ServeHTTP(metricsRecorder, metricsRequest)

	// Then
	if workRecorder.Code != http.StatusOK {
		t.Fatalf("work status = %d, want %d", workRecorder.Code, http.StatusOK)
	}
	if !strings.Contains(metricsRecorder.Body.String(), "cpu_work_requests_total 1") {
		t.Fatalf("metrics = %q, want cpu_work_requests_total 1", metricsRecorder.Body.String())
	}
}

func TestServer_rejectsCPUWork_when_durationIsInvalid(t *testing.T) {
	// Given
	server := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	recorder := httptest.NewRecorder()
	request := httptest.NewRequest(http.MethodGet, "/cpu-work?duration_ms=invalid", nil)

	// When
	server.Handler().ServeHTTP(recorder, request)

	// Then
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
}

func TestServer_acceptsAlertmanagerPayload_when_alertsArePosted(t *testing.T) {
	// Given
	server := New(slog.New(slog.NewTextHandler(io.Discard, nil)))
	recorder := httptest.NewRecorder()
	payload := bytes.NewBufferString(`{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"PodCpuSaturation"}}]}`)
	request := httptest.NewRequest(http.MethodPost, "/alerts", payload)

	// When
	server.Handler().ServeHTTP(recorder, request)

	// Then
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusAccepted)
	}
}
