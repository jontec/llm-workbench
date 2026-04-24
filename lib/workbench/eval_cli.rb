require_relative 'eval_dataset_cli'
require_relative 'eval_scaffolder'
require_relative 'eval_checker'

module Workbench
  class EvalCLI < Thor
    desc "dataset SUBCOMMAND", "Dataset commands (inspect)"
    subcommand "dataset", EvalDatasetCLI

    desc "run", "Run an eval by name or by subject"
    option :name,              type: :string,  desc: "Eval name to run"
    option :subject,           type: :string,  desc: "Run all evals attached to this subject"
    option :continue_on_error, type: :boolean, desc: "Record case errors and continue rather than halting", default: false
    def run_eval
      name    = options[:name]
      subject = options[:subject]

      if name.nil? && subject.nil?
        puts "Error: provide --name <eval_name> or --subject <subject_name>"
        exit 1
      end
      if name && subject
        puts "Error: --name and --subject are mutually exclusive"
        exit 1
      end

      eval_classes = if name
        klass = Eval.find(name)
        unless klass
          puts "Error: eval '#{name}' not found. Check evals/ for available evals."
          exit 1
        end
        [klass]
      else
        eval_classes_for_subject(subject)
      end

      eval_classes.each do |klass|
        runner = EvalRunner.new(klass, continue_on_error: options[:continue_on_error])
        result = runner.run
        EvalRunner.print_result(result)
        output_dir = EvalResultWriter.new(result).write
        puts "Results written to #{output_dir}/"
      end
    end

    map "run" => :run_eval

    desc "create NAME", "Scaffold a new eval, dataset stub, and patch subject(s)"
    option :for, type: :string, required: true, desc: "Subject name(s), comma-separated"
    def create(name)
      subjects  = options[:for].split(',').map(&:strip)
      scaffolder = EvalScaffolder.new(name, subjects)
      errors = scaffolder.create
      if errors.any?
        errors.each { |e| puts "Error: #{e}" }
        exit 1
      end
    end

    desc "link NAME", "Link an existing eval to subject(s)"
    option :for, type: :string, required: true, desc: "Subject name(s), comma-separated"
    def link(name)
      subjects  = options[:for].split(',').map(&:strip)
      scaffolder = EvalScaffolder.new(name, subjects)
      errors = scaffolder.link
      if errors.any?
        errors.each { |e| puts "Error: #{e}" }
        exit 1
      end
    end

    desc "check", "Validate eval linkage and project consistency"
    def check
      checker = EvalChecker.new
      issues  = checker.check
      if issues.empty?
        puts "No issues found."
        exit 0
      else
        issues.each { |i| puts EvalChecker.format_issue(i) }
        exit 1
      end
    end

    private

    def eval_classes_for_subject(subject_name)
      resolved = Workbench.resolve(subject_name)
      eval_names = if resolved[:type] == 'pipeline'
        pipeline = Pipeline.find(subject_name)
        pipeline.eval_names
      else
        Task.find(subject_name).eval_names
      end

      if eval_names.empty?
        puts "Error: no evals attached to subject '#{subject_name}'."
        puts "       Use 'evaluated_by' in the subject definition to attach evals."
        exit 1
      end

      eval_names.map do |eval_name|
        klass = Eval.find(eval_name.to_s)
        unless klass
          puts "Error: eval '#{eval_name}' declared by '#{subject_name}' could not be found."
          exit 1
        end
        klass
      end
    end
  end
end
