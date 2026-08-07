package main

import (
	"context"
	"log/slog"
	"os"
	"os/signal"
	"syscall"

	"github.com/yuminkim/k8s-monitoring/internal/benchmark"
)

func main() {
	logger := slog.New(slog.NewJSONHandler(os.Stdout, &slog.HandlerOptions{Level: slog.LevelInfo}))
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	config, err := benchmark.LoadIngestConfig()
	if err != nil {
		logger.Error("load ingest configuration", slog.Any("error", err))
		os.Exit(1)
	}
	publisher := benchmark.NewKafkaPublisher(config.Brokers, config.Topic)
	defer func() {
		if err := publisher.Close(); err != nil {
			logger.Error("close kafka publisher", slog.Any("error", err))
		}
	}()
	metrics, registry := benchmark.NewMetrics()
	application := benchmark.NewHTTPApplication(config.Address, benchmark.NewIngestServer(publisher, metrics, registry), logger)
	if err := application.Run(ctx); err != nil {
		logger.Error("ingest stopped unexpectedly", slog.Any("error", err))
		os.Exit(1)
	}
}
