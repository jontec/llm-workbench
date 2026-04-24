require 'yaml'
require 'active_support/core_ext/string'

module Workbench
  class EvalChecker
    Issue = Struct.new(:type, :details, keyword_init: true)

    def initialize(eval_dir: EvalDir, task_dir: TaskDir, pipeline_dir: PipelineDir,
                   dataset_dir: DatasetDir, fixtures_dir: FixturesDir)
      @eval_dir     = eval_dir
      @task_dir     = task_dir
      @pipeline_dir = pipeline_dir
      @dataset_dir  = dataset_dir
      @fixtures_dir = fixtures_dir
    end

    def check
      evals            = load_evals
      task_subjects    = load_task_subjects
      pipeline_subjects = load_pipeline_subjects
      all_subjects     = task_subjects + pipeline_subjects

      all_subject_names      = all_subjects.map { |s| s[:name] }.to_set
      all_declared_eval_names = all_subjects.flat_map { |s| s[:eval_names] }.to_set

      issues = []
      issues += check_missing_evals(all_subjects, evals)
      issues += check_missing_subjects(evals, all_subject_names)
      issues += check_orphaned_evals(evals, all_declared_eval_names)
      issues += check_broken_datasets(evals)
      issues
    end

    def self.format_issue(issue)
      case issue.type
      when :missing_eval
        "[missing-eval]    subject '#{issue.details[:subject]}' declares evaluated_by :#{issue.details[:eval]}, but no such eval exists"
      when :missing_subject
        "[missing-subject] eval '#{issue.details[:eval]}' declares evaluates :#{issue.details[:subject]}, but no such subject exists"
      when :orphaned_eval
        "[orphaned-eval]   eval '#{issue.details[:eval]}' has no subject link (no evaluated_by and no evaluates declaration)"
      when :broken_dataset
        "[broken-dataset]  eval '#{issue.details[:eval]}' dataset '#{issue.details[:dataset]}': #{issue.details[:error]}"
      end
    end

    private

    # -------------------------------------------------------------------------
    # File-based parsing — avoids global require/ObjectSpace state
    # -------------------------------------------------------------------------

    def load_evals
      Dir.glob(File.join(@eval_dir, '**', '*.rb')).sort.filter_map do |file|
        content     = File.read(file)
        class_match = content.match(/^class (\w+)\s*<\s*(?:Workbench::)?Eval\b/)
        next unless class_match

        {
          eval_name:    class_match[1].underscore.to_sym,
          subject_names: content.scan(/^\s*evaluates\s+:(\w+)/).flatten.map(&:to_sym),
          dataset_name:  content.match(/^\s*dataset\s+:(\w+)/)&.[](1)&.to_sym
        }
      end
    end

    def load_task_subjects
      return [] unless File.directory?(@task_dir)
      Dir.glob(File.join(@task_dir, '*.rb')).sort.filter_map do |file|
        content     = File.read(file)
        class_match = content.match(/^class (\w+)\s*<\s*(?:Workbench::)?Task\b/)
        next unless class_match

        {
          name:       class_match[1].underscore.to_sym,
          eval_names: content.scan(/^\s*evaluated_by\s+:(\w+)/).flatten.map(&:to_sym)
        }
      end
    end

    def load_pipeline_subjects
      return [] unless File.directory?(@pipeline_dir)
      Dir.glob(File.join(@pipeline_dir, '*.y*ml')).sort.filter_map do |file|
        data = YAML.load_file(file) || {}
        {
          name:       (data['name'] || File.basename(file, '.*')).to_sym,
          eval_names: Array(data['evaluated_by']).map(&:to_sym)
        }
      end
    end

    # -------------------------------------------------------------------------
    # Checks
    # -------------------------------------------------------------------------

    def check_missing_evals(subjects, evals)
      existing = evals.map { |e| e[:eval_name] }.to_set
      subjects.flat_map do |subject|
        subject[:eval_names].filter_map do |eval_name|
          unless existing.include?(eval_name)
            Issue.new(type: :missing_eval, details: { subject: subject[:name], eval: eval_name })
          end
        end
      end
    end

    def check_missing_subjects(evals, subject_names)
      evals.flat_map do |eval_info|
        eval_info[:subject_names].filter_map do |subject_name|
          unless subject_names.include?(subject_name)
            Issue.new(type: :missing_subject, details: { eval: eval_info[:eval_name], subject: subject_name })
          end
        end
      end
    end

    def check_orphaned_evals(evals, declared_eval_names)
      evals.filter_map do |eval_info|
        linked = declared_eval_names.include?(eval_info[:eval_name]) || eval_info[:subject_names].any?
        Issue.new(type: :orphaned_eval, details: { eval: eval_info[:eval_name] }) unless linked
      end
    end

    def check_broken_datasets(evals)
      evals.filter_map do |eval_info|
        next unless eval_info[:dataset_name]

        dataset_yml = File.join(@dataset_dir, "#{eval_info[:dataset_name]}.yml")
        unless File.exist?(dataset_yml)
          next Issue.new(type: :broken_dataset, details: {
            eval:    eval_info[:eval_name],
            dataset: eval_info[:dataset_name],
            error:   "Dataset file not found: #{dataset_yml}"
          })
        end

        data        = YAML.load_file(dataset_yml) || {}
        fixture_rel = data['path'] || eval_info[:dataset_name].to_s
        fixture_abs = File.expand_path(File.join(@fixtures_dir, fixture_rel))

        unless File.exist?(fixture_abs)
          next Issue.new(type: :broken_dataset, details: {
            eval:    eval_info[:eval_name],
            dataset: eval_info[:dataset_name],
            error:   "Fixture path does not exist: #{fixture_abs}"
          })
        end

        files = Dir.glob(File.join(fixture_abs, '**', '*')).select { |f| File.file?(f) }
        if files.empty?
          Issue.new(type: :broken_dataset, details: {
            eval:    eval_info[:eval_name],
            dataset: eval_info[:dataset_name],
            error:   "Dataset discovered zero cases"
          })
        end
      end.compact
    end
  end
end
