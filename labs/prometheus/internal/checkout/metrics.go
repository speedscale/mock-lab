package checkout

import (
	"net/http"
	"strconv"
	"syscall"
	"time"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/collectors"
)

// Metrics holds the three lab signals: the request-duration histogram is the
// symptom, the connection-wait histogram is the cause, and the CPU counter
// rules out compute.
type Metrics struct {
	requestDuration *prometheus.HistogramVec
	connWait        prometheus.Histogram
}

// NewMetrics registers the lab's collectors on a fresh registry.
func NewMetrics(registry *prometheus.Registry) *Metrics {
	metrics := &Metrics{
		requestDuration: prometheus.NewHistogramVec(prometheus.HistogramOpts{
			Name:    "checkout_request_duration_seconds",
			Help:    "Inbound request duration by route, method, and status code.",
			Buckets: []float64{0.01, 0.025, 0.05, 0.075, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5, 0.75, 1, 2.5},
		}, []string{"route", "method", "code"}),
		connWait: prometheus.NewHistogram(prometheus.HistogramOpts{
			Name:    "pricing_conn_wait_seconds",
			Help:    "Time a pricing call waited for a pooled connection before sending.",
			Buckets: []float64{0.0005, 0.001, 0.0025, 0.005, 0.01, 0.025, 0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 1, 2.5},
		}),
	}
	registry.MustRegister(
		metrics.requestDuration,
		metrics.connWait,
		newCPUCounter(),
		collectors.NewGoCollector(),
	)
	return metrics
}

// ObserveConnWait records one pricing connection acquisition delay.
func (m *Metrics) ObserveConnWait(waited time.Duration) {
	m.connWait.Observe(waited.Seconds())
}

// InstrumentRoute wraps an API handler with the request-duration histogram.
func (m *Metrics) InstrumentRoute(route string, next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		started := time.Now()
		recorder := &statusRecorder{ResponseWriter: w, code: http.StatusOK}
		next.ServeHTTP(recorder, r)
		m.requestDuration.
			WithLabelValues(route, r.Method, strconv.Itoa(recorder.code)).
			Observe(time.Since(started).Seconds())
	})
}

type statusRecorder struct {
	http.ResponseWriter
	code        int
	wroteHeader bool
}

func (r *statusRecorder) WriteHeader(code int) {
	if !r.wroteHeader {
		r.code = code
		r.wroteHeader = true
	}
	r.ResponseWriter.WriteHeader(code)
}

// newCPUCounter reads process CPU time through getrusage so the same counter
// works on the macOS and Linux hosts this lab runs on; client_golang's process
// collector is Linux-only.
func newCPUCounter() prometheus.CounterFunc {
	return prometheus.NewCounterFunc(prometheus.CounterOpts{
		Name: "app_cpu_seconds_total",
		Help: "Total user plus system CPU time consumed by the checkout process.",
	}, func() float64 {
		var usage syscall.Rusage
		if err := syscall.Getrusage(syscall.RUSAGE_SELF, &usage); err != nil {
			return 0
		}
		return timevalSeconds(usage.Utime) + timevalSeconds(usage.Stime)
	})
}

func timevalSeconds(value syscall.Timeval) float64 {
	return float64(value.Sec) + float64(value.Usec)/1e6
}
