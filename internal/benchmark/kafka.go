package benchmark

import (
	"context"
	"encoding/json"
	"fmt"
	"strconv"
	"time"

	"github.com/segmentio/kafka-go"
)

type KafkaPublisher struct {
	writer *kafka.Writer
}

func NewKafkaPublisher(brokers []string, topic string) *KafkaPublisher {
	return &KafkaPublisher{writer: &kafka.Writer{
		Addr:         kafka.TCP(brokers...),
		Topic:        topic,
		RequiredAcks: kafka.RequireAll,
		BatchSize:    100,
		BatchTimeout: 10 * time.Millisecond,
		Balancer:     &kafka.Hash{},
	}}
}

func (publisher *KafkaPublisher) Publish(ctx context.Context, event Event) error {
	value, err := json.Marshal(event.Input())
	if err != nil {
		return fmt.Errorf("encode event %d: %w", event.EventID(), err)
	}
	if err := publisher.writer.WriteMessages(ctx, kafka.Message{
		Key:   []byte(strconv.FormatUint(event.EventID(), 10)),
		Value: value,
	}); err != nil {
		return fmt.Errorf("write event %d: %w", event.EventID(), err)
	}
	return nil
}

func (publisher *KafkaPublisher) Close() error {
	if err := publisher.writer.Close(); err != nil {
		return fmt.Errorf("close kafka writer: %w", err)
	}
	return nil
}

type KafkaSource struct {
	reader *kafka.Reader
}

func NewKafkaSource(brokers []string, topic, groupID string) *KafkaSource {
	return &KafkaSource{reader: kafka.NewReader(kafka.ReaderConfig{
		Brokers:        brokers,
		Topic:          topic,
		GroupID:        groupID,
		MinBytes:       10_000,
		MaxBytes:       1_000_000,
		MaxWait:        250 * time.Millisecond,
		CommitInterval: 0,
	})}
}

func (source *KafkaSource) Fetch(ctx context.Context) (ReceivedEvent, error) {
	message, err := source.reader.FetchMessage(ctx)
	if err != nil {
		return ReceivedEvent{}, fmt.Errorf("fetch kafka message: %w", err)
	}

	var input EventInput
	if err := json.Unmarshal(message.Value, &input); err != nil {
		return ReceivedEvent{}, fmt.Errorf("decode kafka message: %w", err)
	}
	event, err := NewEvent(input)
	if err != nil {
		return ReceivedEvent{}, fmt.Errorf("parse kafka event: %w", err)
	}
	return NewReceivedEvent(event, func(commitContext context.Context) error {
		if err := source.reader.CommitMessages(commitContext, message); err != nil {
			return fmt.Errorf("commit kafka message: %w", err)
		}
		return nil
	}), nil
}

func (source *KafkaSource) Lag() int64 {
	return source.reader.Stats().Lag
}

func (source *KafkaSource) Close() error {
	if err := source.reader.Close(); err != nil {
		return fmt.Errorf("close kafka reader: %w", err)
	}
	return nil
}
