require 'securerandom'

module Workbench
  EvalRunResult = Struct.new(:eval_name, :run_id, :started_at, :finished_at,
                              :dataset_name, :subject_results, keyword_init: true)

  SubjectResult = Struct.new(:subject_name, :case_count, :pass_count, :fail_count,
                              :error_count, :pass_rate, :metrics, :case_results,
                              keyword_init: true)

  class EvalRunner
    def initialize(eval_class, continue_on_error: false)
      @eval_class        = eval_class
      @continue_on_error = continue_on_error
    end

    def run
      run_id     = SecureRandom.hex(6)
      started_at = Time.now

      dataset = Dataset.find(@eval_class.dataset_name)
      cases   = dataset.cases

      instance = @eval_class.new
      instance.setup if instance.respond_to?(:setup)

      @eval_class.subject_names.each do |subject_name|
        cases.each do |eval_case|
          instance.current_subject = subject_name
          instance.current_case    = eval_case
          begin
            instance.run
          rescue => e
            raise unless @continue_on_error
            instance.record_case_result(error: "#{e.class}: #{e.message}")
          end
        end
      end

      instance.teardown if instance.respond_to?(:teardown)

      finished_at     = Time.now
      subject_results = build_subject_results(instance.case_results, @eval_class.subject_names)

      EvalRunResult.new(
        eval_name:       @eval_class.eval_name.to_s,
        run_id:          run_id,
        started_at:      started_at,
        finished_at:     finished_at,
        dataset_name:    @eval_class.dataset_name.to_s,
        subject_results: subject_results
      )
    end

    def self.print_result(result)
      result.subject_results.each do |sr|
        puts "Eval:     #{result.eval_name}"
        puts "Subject:  #{sr.subject_name}"
        puts "Dataset:  #{result.dataset_name} (#{sr.case_count} cases)"
        puts

        if sr.pass_rate
          puts "  Pass rate:  #{sr.pass_count}/#{sr.case_count}  (#{format('%.1f', sr.pass_rate * 100)}%)"
        end

        (sr.metrics || {}).each do |name, value|
          puts "  #{name}:#{metric_padding(name)}#{format('%.3f', value)}"
        end

        failures = sr.case_results.select { |r| r[:passed] == false && r[:error].nil? }
        errors   = sr.case_results.select { |r| r[:error] }

        if failures.any? || errors.any?
          puts
          failures.each { |r| puts "  FAILED  #{r[:case_id]}#{case_metrics_summary(r)}" }
          errors.each   { |r| puts "  ERROR   #{r[:case_id]}  #{r[:error]}" }
        end

        puts
      end
    end

    private

    def build_subject_results(all_case_results, subject_names)
      subject_names.map do |subject_name|
        case_results = all_case_results.select { |r| r[:subject] == subject_name }

        pass_count  = case_results.count { |r| r[:passed] == true }
        fail_count  = case_results.count { |r| r[:passed] == false }
        error_count = case_results.count { |r| r[:error] }

        has_pass_info = case_results.any? { |r| !r[:passed].nil? }
        pass_rate     = has_pass_info ? pass_count.to_f / case_results.length : nil

        metrics = aggregate_metrics(case_results)

        SubjectResult.new(
          subject_name: subject_name,
          case_count:   case_results.length,
          pass_count:   pass_count,
          fail_count:   fail_count,
          error_count:  error_count,
          pass_rate:    pass_rate,
          metrics:      metrics,
          case_results: case_results
        )
      end
    end

    def aggregate_metrics(case_results)
      return {} unless @eval_class.metric_definitions
      @eval_class.metric_definitions.transform_values.with_index do |defn, i|
        name   = @eval_class.metric_definitions.keys[i]
        values = case_results.map { |r| r[:metrics][name] }.compact
        next nil if values.empty?
        aggregate(values, defn[:type])
      end.compact
    end

    def aggregate(values, type)
      case type
      when :average then values.sum.to_f / values.length
      when :sum     then values.sum
      when :count   then values.length
      when :min     then values.min
      when :max     then values.max
      end
    end

    def metric_padding(name)
      width = (@eval_class.metric_definitions&.keys&.map { |k| k.length }&.max || 0) + 2
      " " * [width - name.to_s.length, 1].max
    end

    def case_metrics_summary(result)
      return "" if result[:metrics].nil? || result[:metrics].empty?
      pairs = result[:metrics].map { |k, v| "#{k}: #{format('%.3f', v)}" }.join(", ")
      "  (#{pairs})"
    end
  end
end
