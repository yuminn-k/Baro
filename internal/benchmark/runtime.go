package benchmark

import (
	"context"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"time"
)

type HTTPApplication struct {
	address string
	handler http.Handler
	logger  *slog.Logger
}

func NewHTTPApplication(address string, handler http.Handler, logger *slog.Logger) HTTPApplication {
	return HTTPApplication{address: address, handler: handler, logger: logger}
}

func (application HTTPApplication) Run(ctx context.Context) error {
	server := &http.Server{
		Addr:              application.address,
		Handler:           application.handler,
		ReadHeaderTimeout: 5 * time.Second,
		ReadTimeout:       10 * time.Second,
		WriteTimeout:      15 * time.Second,
		IdleTimeout:       60 * time.Second,
	}
	errorsChannel := make(chan error, 1)
	go func() {
		application.logger.InfoContext(ctx, "benchmark HTTP server starting", slog.String("address", application.address))
		errorsChannel <- server.ListenAndServe()
	}()

	select {
	case <-ctx.Done():
		shutdownContext, cancel := context.WithTimeout(context.Background(), 20*time.Second)
		defer cancel()
		if err := server.Shutdown(shutdownContext); err != nil {
			return fmt.Errorf("shutdown HTTP server: %w", err)
		}
		return nil
	case err := <-errorsChannel:
		if errors.Is(err, http.ErrServerClosed) {
			return nil
		}
		return fmt.Errorf("run HTTP server: %w", err)
	}
}
