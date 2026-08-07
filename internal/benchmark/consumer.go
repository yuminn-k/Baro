package benchmark

import (
	"context"
	"fmt"
)

type SaveResult uint8

const (
	SaveInserted SaveResult = iota
	SaveConflicted
)

type EventStore interface {
	Save(context.Context, Event) (SaveResult, error)
}

type ConsumerObserver interface {
	Inserted(Event)
	Conflicted(Event)
}

type NopConsumerObserver struct{}

func (NopConsumerObserver) Inserted(Event)   {}
func (NopConsumerObserver) Conflicted(Event) {}

type ReceivedEvent struct {
	event  Event
	commit func(context.Context) error
}

func NewReceivedEvent(event Event, commit func(context.Context) error) ReceivedEvent {
	return ReceivedEvent{event: event, commit: commit}
}

func (received ReceivedEvent) Event() Event {
	return received.event
}

func (received ReceivedEvent) Commit(ctx context.Context) error {
	if err := received.commit(ctx); err != nil {
		return fmt.Errorf("commit event %d: %w", received.event.EventID(), err)
	}
	return nil
}

type ConsumerProcessor struct {
	store    EventStore
	observer ConsumerObserver
}

func NewConsumerProcessor(store EventStore, observer ConsumerObserver) ConsumerProcessor {
	return ConsumerProcessor{store: store, observer: observer}
}

func (processor ConsumerProcessor) Process(ctx context.Context, received ReceivedEvent) error {
	result, err := processor.store.Save(ctx, received.Event())
	if err != nil {
		return fmt.Errorf("save event %d: %w", received.Event().EventID(), err)
	}
	if err := received.Commit(ctx); err != nil {
		return err
	}

	switch result {
	case SaveInserted:
		processor.observer.Inserted(received.Event())
	case SaveConflicted:
		processor.observer.Conflicted(received.Event())
	default:
		return fmt.Errorf("event %d: unknown save result %d", received.Event().EventID(), result)
	}
	return nil
}
