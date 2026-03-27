module Workbench
  class InputValidator
    def initialize(pipeline)
      @pipeline = pipeline
    end

    # Input definitions expected from the HTTP request body:
    # all declared inputs across all tasks, minus any keys produced as outputs
    # by a preceding task (those are satisfied internally by the pipeline).
    def external_inputs
      output_keys = @pipeline.task_list.each_with_object(Set.new) do |task, set|
        (task.class.output_definitions || {}).each_key { |k| set << k }
      end

      @pipeline.task_list.each_with_object({}) do |task, acc|
        (task.class.input_definitions || {}).each do |key, opts|
          acc[key] = opts unless output_keys.include?(key)
        end
      end
    end

    # Returns an array of field name strings for required inputs missing from body.
    # An empty array means the body is valid.
    def validate(body)
      external_inputs.each_with_object([]) do |(key, opts), missing|
        next if opts[:optional]
        missing << key.to_s unless body.key?(key.to_s) || body.key?(key)
      end
    end
  end
end
