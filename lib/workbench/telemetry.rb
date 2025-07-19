# require 'opentelemetry/sdk'
# require_relative 'open_telemetry/exporters/simple_console_span_exporter'
# require 'opentelemetry/exporter/console'

OpenTelemetry::SDK.configure do |c|
  c.add_span_processor(
    OpenTelemetry::SDK::Trace::Export::SimpleSpanProcessor.new(
      OpenTelemetry::SDK::Trace::Export::SimpleConsoleSpanExporter.new
    )
  )
end

module Workbench
  module Telemetry
    def open_span(name)
      raise "No tracer defined" unless @telemetry
      span = @telemetry.start_span(name)
      ctx = OpenTelemetry::Trace.context_with_span(span)
      @otel_span_stack ||= []
      @otel_span_stack.push([span, ctx])
      OpenTelemetry::Context.with_current(ctx) {}
    end

    def close_span(name = nil)
      span, _ctx = @otel_span_stack.pop
      if name && span.name != name
        raise "Closing span #{span.name}, but you asked to close #{name}"
      end
      span.finish
    end

    def current_span
      @otel_span_stack&.last&.first
    end

    def log_attr(key, value)
      current_span&.set_attribute(key, value)
    end
  end
end