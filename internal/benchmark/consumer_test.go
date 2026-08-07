package benchmark

import (
	"context"
	"errors"
	"testing"
)

type recordingStore struct {
	result SaveResult
	err    error
	called bool
}

func (store *recordingStore) Save(_ context.Context, _ Event) (SaveResult, error) {
	store.called = true
	return store.result, store.err
}

type recordingObserver struct {
	inserted  int
	conflicts int
}

func (observer *recordingObserver) Inserted(Event)   { observer.inserted++ }
func (observer *recordingObserver) Conflicted(Event) { observer.conflicts++ }

func TestProcessReceivedEvent_commitsAfterSuccessfulStore(t *testing.T) {
	// Given
	event, err := NewEvent(EventInput{EventID: 1, SubmittedAtUnixMilli: 1, Payload: "benchmark"})
	if err != nil {
		t.Fatalf("NewEvent() error = %v", err)
	}
	store := &recordingStore{result: SaveInserted}
	committed := false
	received := NewReceivedEvent(event, func(context.Context) error {
		if !store.called {
			t.Fatal("commit called before store")
		}
		committed = true
		return nil
	})
	observer := &recordingObserver{}

	// When
	err = NewConsumerProcessor(store, observer).Process(context.Background(), received)

	// Then
	if err != nil {
		t.Fatalf("ProcessReceivedEvent() error = %v", err)
	}
	if !committed {
		t.Fatal("event was not committed")
	}
	if observer.inserted != 1 {
		t.Fatalf("inserted = %d, want 1", observer.inserted)
	}
}

func TestProcessReceivedEvent_doesNotCommitWhenStoreFails(t *testing.T) {
	// Given
	event, err := NewEvent(EventInput{EventID: 1, SubmittedAtUnixMilli: 1, Payload: "benchmark"})
	if err != nil {
		t.Fatalf("NewEvent() error = %v", err)
	}
	committed := false
	received := NewReceivedEvent(event, func(context.Context) error {
		committed = true
		return nil
	})
	store := &recordingStore{err: errors.New("postgres unavailable")}

	// When
	err = NewConsumerProcessor(store, NopConsumerObserver{}).Process(context.Background(), received)

	// Then
	if err == nil {
		t.Fatal("ProcessReceivedEvent() error = nil, want error")
	}
	if committed {
		t.Fatal("event committed after a failed store")
	}
}
