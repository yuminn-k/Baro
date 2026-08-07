package benchmark

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

type recordingPublisher struct {
	event Event
	err   error
}

func (publisher *recordingPublisher) Publish(_ context.Context, event Event) error {
	publisher.event = event
	return publisher.err
}

func TestIngestHandler_acceptsValidEvent(t *testing.T) {
	// Given
	publisher := &recordingPublisher{}
	handler := NewIngestHandler(publisher, NopIngestObserver{})
	request := httptest.NewRequest(http.MethodPost, "/events", bytes.NewBufferString(`{"event_id":12,"submitted_at_unix_ms":1700000000000,"payload":"benchmark"}`))
	recorder := httptest.NewRecorder()

	// When
	handler.ServeHTTP(recorder, request)

	// Then
	if recorder.Code != http.StatusAccepted {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusAccepted)
	}
	if publisher.event.EventID() != 12 {
		t.Fatalf("published event ID = %d, want 12", publisher.event.EventID())
	}
}

func TestIngestHandler_returnsBadRequestForInvalidEvent(t *testing.T) {
	// Given
	handler := NewIngestHandler(&recordingPublisher{}, NopIngestObserver{})
	request := httptest.NewRequest(http.MethodPost, "/events", bytes.NewBufferString(`{"event_id":12,"submitted_at_unix_ms":0,"payload":"benchmark"}`))
	recorder := httptest.NewRecorder()

	// When
	handler.ServeHTTP(recorder, request)

	// Then
	if recorder.Code != http.StatusBadRequest {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusBadRequest)
	}
}

func TestIngestHandler_returnsServiceUnavailableWhenKafkaPublishFails(t *testing.T) {
	// Given
	publisher := &recordingPublisher{err: errors.New("kafka unavailable")}
	handler := NewIngestHandler(publisher, NopIngestObserver{})
	request := httptest.NewRequest(http.MethodPost, "/events", bytes.NewBufferString(`{"event_id":12,"submitted_at_unix_ms":1700000000000,"payload":"benchmark"}`))
	recorder := httptest.NewRecorder()

	// When
	handler.ServeHTTP(recorder, request)

	// Then
	if recorder.Code != http.StatusServiceUnavailable {
		t.Fatalf("status = %d, want %d", recorder.Code, http.StatusServiceUnavailable)
	}
}
