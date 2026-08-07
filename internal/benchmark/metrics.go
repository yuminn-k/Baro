package benchmark

import (
	"time"

	"github.com/prometheus/client_golang/prometheus"
)

type Metrics struct {
	accepted  prometheus.Counter
	rejected  prometheus.Counter
	failed    prometheus.Counter
	inserted  prometheus.Counter
	conflicts prometheus.Counter
	lag       prometheus.Gauge
	e2e       prometheus.Histogram
}

func NewMetrics() (*Metrics, *prometheus.Registry) {
	registry := prometheus.NewRegistry()
	metrics := &Metrics{
		accepted:  prometheus.NewCounter(prometheus.CounterOpts{Name: "benchmark_producer_accepted_total", Help: "Events accepted after Kafka acknowledgement."}),
		rejected:  prometheus.NewCounter(prometheus.CounterOpts{Name: "benchmark_producer_rejected_total", Help: "Events rejected at the HTTP boundary."}),
		failed:    prometheus.NewCounter(prometheus.CounterOpts{Name: "benchmark_producer_publish_failed_total", Help: "Kafka publish failures."}),
		inserted:  prometheus.NewCounter(prometheus.CounterOpts{Name: "benchmark_consumer_inserted_total", Help: "New events inserted into PostgreSQL."}),
		conflicts: prometheus.NewCounter(prometheus.CounterOpts{Name: "benchmark_consumer_conflicts_total", Help: "Duplicate events ignored by PostgreSQL."}),
		lag:       prometheus.NewGauge(prometheus.GaugeOpts{Name: "benchmark_consumer_lag", Help: "Local Kafka reader lag in messages."}),
		e2e:       prometheus.NewHistogram(prometheus.HistogramOpts{Name: "benchmark_event_end_to_end_seconds", Help: "Time from ingest submission to PostgreSQL completion.", Buckets: []float64{0.01, 0.05, 0.1, 0.25, 0.5, 1, 2, 5, 10}}),
	}
	registry.MustRegister(metrics.accepted, metrics.rejected, metrics.failed, metrics.inserted, metrics.conflicts, metrics.lag, metrics.e2e)
	return metrics, registry
}

func (metrics *Metrics) Accepted()      { metrics.accepted.Inc() }
func (metrics *Metrics) Rejected()      { metrics.rejected.Inc() }
func (metrics *Metrics) PublishFailed() { metrics.failed.Inc() }

func (metrics *Metrics) Inserted(event Event) {
	metrics.inserted.Inc()
	metrics.e2e.Observe(time.Since(time.UnixMilli(event.SubmittedAtUnixMilli())).Seconds())
}

func (metrics *Metrics) Conflicted(event Event) {
	metrics.conflicts.Inc()
	metrics.e2e.Observe(time.Since(time.UnixMilli(event.SubmittedAtUnixMilli())).Seconds())
}

func (metrics *Metrics) Lag(lag int64) { metrics.lag.Set(float64(lag)) }
