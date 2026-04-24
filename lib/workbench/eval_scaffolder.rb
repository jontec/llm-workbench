require 'yaml'
require 'fileutils'

module Workbench
  class EvalScaffolder
    def initialize(name, subjects, eval_dir: EvalDir, dataset_dir: DatasetDir,
                   task_dir: TaskDir, pipeline_dir: PipelineDir)
      @name         = name
      @subjects     = subjects
      @eval_dir     = eval_dir
      @dataset_dir  = dataset_dir
      @task_dir     = task_dir
      @pipeline_dir = pipeline_dir
    end

    # Create eval file + dataset stub, then link.
    def create
      errors = []
      errors += validate_subjects
      return errors if errors.any?

      write_eval_file
      write_dataset_stub
      link_subjects
      []
    end

    # Link an existing eval to subjects (no file creation).
    def link
      errors = []
      errors += validate_subjects
      eval_file = File.join(@eval_dir, "#{@name}.rb")
      errors << "Eval file '#{eval_file}' does not exist. Use `eval create` to scaffold a new eval." unless File.exist?(eval_file)
      return errors if errors.any?

      link_subjects
      []
    end

    private

    def validate_subjects
      @subjects.map do |subject|
        type, _path = resolve_subject(subject)
        type ? nil : "Cannot resolve '#{subject}' as a known task or pipeline."
      end.compact
    end

    def write_eval_file
      FileUtils.mkdir_p(@eval_dir)
      path       = File.join(@eval_dir, "#{@name}.rb")
      class_name = @name.to_s.split('_').map(&:capitalize).join
      evaluates_lines = @subjects.map { |s| "  evaluates :#{s}" }.join("\n")
      content = <<~RUBY
        class #{class_name} < Workbench::Eval
        #{evaluates_lines}
          dataset :#{@name}
          metric  :pass_rate

          def run
            # result = run_subject(current_subject, inputs: current_case.inputs)
            record_case_result(
              passed:  nil,
              metrics: {}
            )
          end
        end
      RUBY
      File.write(path, content)
      puts "Created #{path}"
    end

    def write_dataset_stub
      FileUtils.mkdir_p(@dataset_dir)
      path = File.join(@dataset_dir, "#{@name}.yml")
      return if File.exist?(path)
      File.write(path, "name: #{@name}\n")
      puts "Created #{path}"
    end

    def link_subjects
      eval_file = File.join(@eval_dir, "#{@name}.rb")

      @subjects.each do |subject|
        type, path = resolve_subject(subject)
        next unless type && path

        if type == 'task'
          patch_ruby_file(path, subject, "evaluated_by :#{@name}")
        else
          patch_pipeline_yaml(path, @name)
        end

        patch_eval_evaluates(eval_file, subject) if File.exist?(eval_file)
      end
    end

    def resolve_subject(name)
      task_glob = Dir.glob(File.join(@task_dir, "#{name}.rb")).first
      return ['task', task_glob] if task_glob

      pipeline_glob = Dir.glob(File.join(@pipeline_dir, "#{name}.y*ml")).first
      return ['pipeline', pipeline_glob] if pipeline_glob

      nil
    end

    # Insert `evaluated_by :<name>` after the class declaration line in a Ruby file.
    def patch_ruby_file(path, _subject, declaration)
      content = File.read(path)
      return if content.include?(declaration)

      patched = content.sub(/^(class \w+ < Workbench::Task\b.*)$/) do
        "#{$1}\n  #{declaration}"
      end

      if patched == content
        puts "Warning: could not patch #{path} — class declaration not found. Add `#{declaration}` manually."
        return
      end

      File.write(path, patched)
      puts "Patched #{path} (added #{declaration})"
    end

    # Add eval name to the evaluated_by list in a pipeline YAML file.
    def patch_pipeline_yaml(path, eval_name)
      content = File.read(path)
      return if content.include?(eval_name.to_s)

      data = YAML.load(content) || {}
      existing = Array(data['evaluated_by']).map(&:to_s)
      return if existing.include?(eval_name.to_s)

      if content =~ /^evaluated_by:/
        # Append to existing list
        patched = content.sub(/^(evaluated_by:.*?)(\n(?!\s*-)|\z)/m) do
          "#{$1}\n  - #{eval_name}#{$2}"
        end
      else
        # Insert after the name: line
        patched = content.sub(/^(name:.*)$/, "\\1\nevaluated_by:\n  - #{eval_name}")
      end

      File.write(path, patched)
      puts "Patched #{path} (added evaluated_by: #{eval_name})"
    end

    # Add `evaluates :subject` to the eval file if not present.
    def patch_eval_evaluates(path, subject)
      declaration = "evaluates :#{subject}"
      content = File.read(path)
      return if content.include?(declaration)

      patched = content.sub(/^(class \w+ < Workbench::Eval\b.*)$/) do
        "#{$1}\n  #{declaration}"
      end

      return if patched == content
      File.write(path, patched)
      puts "Patched #{path} (added #{declaration})"
    end
  end
end
