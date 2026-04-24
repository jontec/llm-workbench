require 'json'
require 'fileutils'

module Workbench
  class EvalResultWriter
    RESULTS_DIR = 'eval_results'

    def initialize(result, base_dir: RESULTS_DIR)
      @result   = result
      @base_dir = base_dir
    end

    def write
      dir = resolve_output_dir
      FileUtils.mkdir_p(dir)
      write_json(dir)
      write_summary(dir)
      dir
    end

    private

    def resolve_output_dir
      date = @result.started_at.strftime('%Y-%m-%d')
      base = File.join(@base_dir, date, @result.eval_name)
      return base unless File.exist?(base)
      n = 2
      loop do
        candidate = "#{base}_#{n}"
        return candidate unless File.exist?(candidate)
        n += 1
      end
    end

    def write_json(dir)
      data = {
        eval:        @result.eval_name,
        run_id:      @result.run_id,
        started_at:  @result.started_at.iso8601,
        finished_at: @result.finished_at.iso8601,
        dataset:     @result.dataset_name,
        subjects:    @result.subject_results.map { |sr| serialize_subject(sr) }
      }
      File.write(File.join(dir, 'run.json'), JSON.pretty_generate(data))
    end

    def serialize_subject(sr)
      {
        subject_name: sr.subject_name,
        case_count:   sr.case_count,
        pass_count:   sr.pass_count,
        fail_count:   sr.fail_count,
        error_count:  sr.error_count,
        pass_rate:    sr.pass_rate,
        metrics:      sr.metrics || {},
        cases:        sr.case_results.map { |r| serialize_case(r) }
      }
    end

    def serialize_case(r)
      {
        case_id:    r[:case_id],
        group_name: r[:group_name],
        passed:     r[:passed],
        error:      r[:error],
        metrics:    r[:metrics] || {},
        outputs:    r[:outputs] || {}
      }
    end

    def write_summary(dir)
      lines = []
      lines << "Eval:      #{@result.eval_name}"
      lines << "Run ID:    #{@result.run_id}"
      lines << "Started:   #{@result.started_at.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << "Finished:  #{@result.finished_at.strftime('%Y-%m-%d %H:%M:%S')}"
      lines << "Dataset:   #{@result.dataset_name}"

      @result.subject_results.each do |sr|
        lines << ""
        lines << "Subject:   #{sr.subject_name}"

        if sr.pass_rate
          lines << "Pass rate: #{sr.pass_count}/#{sr.case_count}  (#{format('%.1f', sr.pass_rate * 100)}%)"
        end

        (sr.metrics || {}).each do |name, value|
          label = "#{name}:"
          lines << "#{label.ljust(11)}#{format('%.3f', value)}"
        end

        failures = sr.case_results.select { |r| r[:passed] == false && r[:error].nil? }
        errors   = sr.case_results.select { |r| r[:error] }

        if failures.any? || errors.any?
          lines << ""
          failures.each { |r| lines << "  FAILED  #{r[:case_id]}#{case_metrics_suffix(r)}" }
          errors.each   { |r| lines << "  ERROR   #{r[:case_id]}  #{r[:error]}" }
        end
      end

      File.write(File.join(dir, 'summary.txt'), lines.join("\n") + "\n")
    end

    def case_metrics_suffix(result)
      return "" if result[:metrics].nil? || result[:metrics].empty?
      pairs = result[:metrics].map { |k, v| "#{k}: #{format('%.3f', v)}" }.join(", ")
      "  (#{pairs})"
    end
  end
end
