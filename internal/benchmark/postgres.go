package benchmark

import (
	"context"
	"fmt"
	"math"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
)

const insertEventSQL = `
INSERT INTO benchmark_events (event_id, submitted_at_unix_ms, payload)
VALUES ($1, $2, $3)
ON CONFLICT (event_id) DO NOTHING`

type PostgresEventStore struct {
	pool *pgxpool.Pool
}

func NewPostgresEventStore(ctx context.Context, databaseURL string) (*PostgresEventStore, error) {
	config, err := pgxpool.ParseConfig(databaseURL)
	if err != nil {
		return nil, fmt.Errorf("parse postgres configuration: %w", err)
	}
	config.MaxConns = 8
	config.MinConns = 1
	config.MaxConnLifetime = time.Hour
	config.MaxConnIdleTime = 15 * time.Minute

	pool, err := pgxpool.NewWithConfig(ctx, config)
	if err != nil {
		return nil, fmt.Errorf("create postgres pool: %w", err)
	}
	if err := pool.Ping(ctx); err != nil {
		pool.Close()
		return nil, fmt.Errorf("ping postgres: %w", err)
	}
	return &PostgresEventStore{pool: pool}, nil
}

func (store *PostgresEventStore) Save(ctx context.Context, event Event) (SaveResult, error) {
	if event.EventID() > math.MaxInt64 {
		return 0, fmt.Errorf("event ID %d exceeds postgres bigint", event.EventID())
	}
	commandTag, err := store.pool.Exec(ctx, insertEventSQL, int64(event.EventID()), event.SubmittedAtUnixMilli(), event.Payload())
	if err != nil {
		return 0, fmt.Errorf("insert event %d: %w", event.EventID(), err)
	}
	if commandTag.RowsAffected() == 0 {
		return SaveConflicted, nil
	}
	return SaveInserted, nil
}

func (store *PostgresEventStore) Close() {
	store.pool.Close()
}
