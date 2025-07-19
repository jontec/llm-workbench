# frozen_string_literal: true

module OpenTelemetry
  module SDK
    module Trace
      module Export
        # Outputs {SpanData} to the console.
        #
        # Potentially useful for exploratory purposes.
        class SimpleConsoleSpanExporter < OpenTelemetry::SDK::Trace::Export::ConsoleSpanExporter

          def export(spans, timeout: nil)
            return FAILURE if @stopped

            Array(spans).each do |span|
              # pp span.to_h
              puts "Span Name: #{ span.name }"
              # puts "Span ID: #{ span.span_id }"
              # puts "Parent Span ID: # span.parent_span_id }" if span.parent_span_id
              puts "Attributes:"
              span.attributes.each do |key, value|
                puts "  #{ key }: #{ value }"
              end
              next unless span.events
              puts "Events:"
              span.events.each do |event|
                puts "  #{ event.name } at #{ timestamp_to_time(event.timestamp) }"
                event.attributes.each do |key, value|
                  puts "    #{ key }: #{ value }"
                end
              end
            end
            # Array(spans).each { |s| pp s }

            SUCCESS
          end
          protected
          def timestamp_to_time(ts)
            Time.at(ts / 1e9)
          end
        end

      end
    end
  end
end
