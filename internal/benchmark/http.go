package benchmark

import (
	"context"
	"encoding/json"
	"net/http"
)

const maximumEventRequestBytes = 1024

type EventPublisher interface {
	Publish(context.Context, Event) error
}

type IngestObserver interface {
	Accepted()
	Rejected()
	PublishFailed()
}

type NopIngestObserver struct{}

func (NopIngestObserver) Accepted()      {}
func (NopIngestObserver) Rejected()      {}
func (NopIngestObserver) PublishFailed() {}

type ingestHandler struct {
	publisher EventPublisher
	observer  IngestObserver
}

func NewIngestHandler(publisher EventPublisher, observer IngestObserver) http.Handler {
	return &ingestHandler{publisher: publisher, observer: observer}
}

func (handler *ingestHandler) ServeHTTP(writer http.ResponseWriter, request *http.Request) {
	if request.Method != http.MethodPost {
		writer.Header().Set("Allow", http.MethodPost)
		http.Error(writer, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	request.Body = http.MaxBytesReader(writer, request.Body, maximumEventRequestBytes)
	defer request.Body.Close()

	var input EventInput
	decoder := json.NewDecoder(request.Body)
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&input); err != nil {
		handler.observer.Rejected()
		http.Error(writer, "invalid event payload", http.StatusBadRequest)
		return
	}

	event, err := NewEvent(input)
	if err != nil {
		handler.observer.Rejected()
		http.Error(writer, "invalid event payload", http.StatusBadRequest)
		return
	}
	if err := handler.publisher.Publish(request.Context(), event); err != nil {
		handler.observer.PublishFailed()
		http.Error(writer, "event unavailable", http.StatusServiceUnavailable)
		return
	}

	handler.observer.Accepted()
	writer.WriteHeader(http.StatusAccepted)
}
