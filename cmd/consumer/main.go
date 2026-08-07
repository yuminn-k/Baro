package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"golang.org/x/sync/errgroup"

	"github.com/yuminkim/k8s-monitoring/internal/benchmark"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	config, err := benchmark.LoadConsumerConfig()
	if err != nil {
		logger.Error("load consumer configuration", slog.Any("error", err))
		os.Exit(1)
	}
	store, err := benchmark.NewPostgresEventStore(ctx, config.DatabaseURL)
	if err != nil {
		logger.Error("connect to postgres", slog.Any("error", err))
		os.Exit(1)
	}
	defer store.Close()
	source := benchmark.NewKafkaSource(config.Brokers, config.Topic, config.GroupID)
	defer func() {
		if err := source.Close(); err != nil {
			logger.Error("close kafka consumer", slog.Any("error", err))
		}
	}()
	metrics, registry := benchmark.NewMetrics()
	processor := benchmark.NewConsumerProcessor(store, metrics)
	consumer := benchmark.NewKafkaConsumer(source, processor, metrics)
	application := benchmark.NewHTTPApplication(config.Address, benchmark.NewConsumerServer(registry), logger)

	group, groupContext := errgroup.WithContext(ctx)
	group.Go(func() error { return application.Run(groupContext) })
	group.Go(func() error { return consumer.Run(groupContext) })
	if err := group.Wait(); err != nil {
		logger.Error("consumer stopped unexpectedly", slog.Any("error", err))
		os.Exit(1)
	}
}
