package benchmark

import (
	"errors"
	"testing"
)

func TestNewEvent_rejectsEmptyPayload(t *testing.T) {
	// Given
	input := EventInput{EventID: 0, SubmittedAtUnixMilli: 1, Payload: ""}

	// When
	_, err := NewEvent(input)

	// Then
	if !errors.Is(err, ErrInvalidEventPayload) {
		t.Fatalf("error = %v, want ErrInvalidEventPayload", err)
	}
}

func TestNewEvent_acceptsBoundedPayload(t *testing.T) {
	// Given
	input := EventInput{EventID: 999_999, SubmittedAtUnixMilli: 1_700_000_000_000, Payload: "benchmark"}

	// When
	event, err := NewEvent(input)

	// Then
	if err != nil {
		t.Fatalf("NewEvent() error = %v", err)
	}
	if event.EventID() != input.EventID {
		t.Fatalf("EventID() = %d, want %d", event.EventID(), input.EventID)
	}
}
