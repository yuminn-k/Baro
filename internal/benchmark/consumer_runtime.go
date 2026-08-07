package benchmark

import (
	"context"
	"errors"
	"fmt"
)

type KafkaConsumer struct {
	source    *KafkaSource
	processor ConsumerProcessor
	metrics   *Metrics
}

func NewKafkaConsumer(source *KafkaSource, processor ConsumerProcessor, metrics *Metrics) KafkaConsumer {
	return KafkaConsumer{source: source, processor: processor, metrics: metrics}
}

func (consumer KafkaConsumer) Run(ctx context.Context) error {
	for {
		received, err := consumer.source.Fetch(ctx)
		if err != nil {
			if errors.Is(err, context.Canceled) || errors.Is(err, context.DeadlineExceeded) {
				return nil
			}
			return err
		}
		if err := consumer.processor.Process(ctx, received); err != nil {
			return fmt.Errorf("process received event: %w", err)
		}
		consumer.metrics.Lag(consumer.source.Lag())
	}
}
