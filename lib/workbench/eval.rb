require 'active_support/core_ext/string'

module Workbench
  EvalDir = 'evals'

  class Eval
    METRIC_TYPES = %i[average sum count min max].freeze

    # -------------------------------------------------------------------------
    # Class-level DSL and registry
    # -------------------------------------------------------------------------

    class << self
      attr_reader :dataset_name, :metric_definitions

      def evaluates(name)
        @subject_names ||= []
        @subject_names << name.to_sym
      end

      def subject_names
        @subject_names || []
      end

      def dataset(name)
        @dataset_name = name.to_sym
      end

      def metric(name, type: :average)
        raise ArgumentError, "Unknown metric type: #{type}" unless METRIC_TYPES.include?(type)
        @metric_definitions ||= {}
        @metric_definitions[name.to_sym] = { type: type }
      end

      def eval_name
        name.to_s.demodulize.underscore.to_sym
      end

      # Registry populated via inherited hook
      def subclasses
        Eval.instance_variable_get(:@subclasses) || []
      end

      def inherited(subclass)
        super
        Eval.instance_variable_set(:@subclasses, subclasses + [subclass])
      end

      def all(eval_dir = EvalDir)
        Dir.glob(File.join(eval_dir, '**', '*.rb')).sort.each do |file|
          require File.expand_path(file)
        end
        subclasses
      end

      def find(name, eval_dir = EvalDir)
        all(eval_dir)
        subclasses.find { |s| s.eval_name == name.to_sym }
      end

      def for_subject(name, eval_dir = EvalDir)
        all(eval_dir)
        subclasses.select { |s| s.subject_names.include?(name.to_sym) }
      end
    end

    # -------------------------------------------------------------------------
    # Instance API
    # -------------------------------------------------------------------------

    attr_accessor :current_subject, :current_case

    def run
      raise NotImplementedError, "#{self.class} must implement #run"
    end

    def run_subject(subject_name, inputs: {})
      resolved = Workbench.resolve(subject_name.to_s)
      pipeline = if resolved[:type] == 'pipeline'
        Pipeline.find(subject_name.to_s)
      else
        Pipeline.lambda([subject_name.to_s])
      end
      pipeline.context.merge!(inputs.transform_keys(&:to_sym))
      pipeline.run
      pipeline.context
    end

    def record_case_result(passed: nil, metrics: {}, outputs: {}, error: nil)
      @case_results ||= []
      @case_results << {
        case_id:    current_case&.id,
        group_name: current_case&.group_name,
        subject:    current_subject,
        passed:     passed,
        metrics:    metrics,
        outputs:    outputs,
        error:      error
      }
    end

    def case_results
      @case_results || []
    end
  end
end
