package observability

import (
	"context"
	"fmt"
	"log/slog"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/exporters/otlp/otlptrace/otlptracehttp"
	"go.opentelemetry.io/otel/exporters/stdout/stdouttrace"
	"go.opentelemetry.io/otel/propagation"
	"go.opentelemetry.io/otel/sdk/resource"
	sdktrace "go.opentelemetry.io/otel/sdk/trace"
	semconv "go.opentelemetry.io/otel/semconv/v1.24.0"
)

// InitTracer sets a global OpenTelemetry tracer provider.
// When endpoint is set, OTLP/HTTP export is used; otherwise stdout export is used.
func InitTracer(enabled bool, service, endpoint string) (func(context.Context) error, error) {
	if !enabled {
		return func(context.Context) error { return nil }, nil
	}

	ctx := context.Background()
	var exporter sdktrace.SpanExporter
	var err error
	if strings.TrimSpace(endpoint) != "" {
		exporter, err = otlptracehttp.New(ctx, otlptracehttp.WithEndpoint(strings.TrimSpace(endpoint)), otlptracehttp.WithInsecure())
		if err != nil {
			return nil, fmt.Errorf("create otlp trace exporter: %w", err)
		}
		slog.Info("otel trace exporter configured", "type", "otlphttp", "endpoint", endpoint)
	} else {
		exporter, err = stdouttrace.New(stdouttrace.WithPrettyPrint())
		if err != nil {
			return nil, fmt.Errorf("create stdout trace exporter: %w", err)
		}
		slog.Info("otel trace exporter configured", "type", "stdout")
	}

	res, err := resource.New(ctx,
		resource.WithAttributes(
			semconv.ServiceName(service),
		),
	)
	if err != nil {
		return nil, fmt.Errorf("create otel resource: %w", err)
	}

	tp := sdktrace.NewTracerProvider(
		sdktrace.WithBatcher(exporter),
		sdktrace.WithResource(res),
	)
	otel.SetTracerProvider(tp)
	otel.SetTextMapPropagator(propagation.TraceContext{})

	return func(ctx context.Context) error {
		shutdownCtx, cancel := context.WithTimeout(ctx, 5*time.Second)
		defer cancel()
		return tp.Shutdown(shutdownCtx)
	}, nil
}
