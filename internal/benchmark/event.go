package benchmark

import (
	"errors"
	"fmt"
)

const maximumPayloadBytes = 256

var (
	ErrInvalidEventPayload = errors.New("benchmark: invalid event payload")
	ErrInvalidSubmittedAt  = errors.New("benchmark: invalid submitted_at_unix_ms")
)

type EventInput struct {
	EventID              uint64 `json:"event_id"`
	SubmittedAtUnixMilli int64  `json:"submitted_at_unix_ms"`
	Payload              string `json:"payload"`
}

type Event struct {
	eventID              uint64
	submittedAtUnixMilli int64
	payload              string
}

func NewEvent(input EventInput) (Event, error) {
	if input.SubmittedAtUnixMilli <= 0 {
		return Event{}, fmt.Errorf("submitted_at_unix_ms=%d: %w", input.SubmittedAtUnixMilli, ErrInvalidSubmittedAt)
	}
	if len(input.Payload) == 0 || len(input.Payload) > maximumPayloadBytes {
		return Event{}, fmt.Errorf("payload_bytes=%d: %w", len(input.Payload), ErrInvalidEventPayload)
	}
	return Event{
		eventID:              input.EventID,
		submittedAtUnixMilli: input.SubmittedAtUnixMilli,
		payload:              input.Payload,
	}, nil
}

func (event Event) EventID() uint64 {
	return event.eventID
}

func (event Event) SubmittedAtUnixMilli() int64 {
	return event.submittedAtUnixMilli
}

func (event Event) Payload() string {
	return event.payload
}

func (event Event) Input() EventInput {
	return EventInput{
		EventID:              event.eventID,
		SubmittedAtUnixMilli: event.submittedAtUnixMilli,
		Payload:              event.payload,
	}
}
