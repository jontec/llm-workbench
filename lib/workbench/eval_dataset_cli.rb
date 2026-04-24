module Workbench
  class EvalDatasetCLI < Thor

    desc "inspect NAME", "Inspect a dataset's discovered cases and file membership"
    def show(name)
      begin
        dataset = Dataset.find(name)
        cases   = dataset.cases
      rescue ArgumentError => e
        puts "Error: #{e.message}"
        exit 1
      end

      print_header(dataset, cases)
      print_cases(dataset, cases)
      print_warnings(dataset)
    end

    map "inspect" => :show

    private

    def print_header(dataset, cases)
      mode_label = dataset.directory_mode || 'default'
      if dataset.directory_mode == 'group'
        group_count = cases.map(&:group_name).compact.uniq.length
        puts "Dataset:  #{dataset.name}"
        puts "Path:     fixtures/#{dataset.path}"
        puts "Mode:     group (#{group_count} #{pluralize(group_count, 'group')}, #{cases.length} #{pluralize(cases.length, 'case')})"
      else
        puts "Dataset:  #{dataset.name}"
        puts "Path:     fixtures/#{dataset.path}"
        puts "Mode:     #{mode_label} (#{cases.length} #{pluralize(cases.length, 'case')})"
      end
    end

    def print_cases(dataset, cases)
      if dataset.directory_mode == 'group'
        groups = cases.map(&:group_name).compact.uniq
        groups.each do |group_name|
          puts ""
          puts "  [#{group_name}]"
          cases.select { |c| c.group_name == group_name }.each do |c|
            print_case(c, indent: '    ')
          end
        end
      else
        puts ""
        cases.each { |c| print_case(c, indent: '  ') }
      end
    end

    def print_case(eval_case, indent:)
      puts "#{indent}#{eval_case.id}/"
      eval_case.files.each do |f|
        tag = if eval_case.inputs.include?(f)
          "  → input"
        elsif eval_case.outputs.include?(f)
          "  → output"
        else
          ""
        end
        puts "#{indent}  #{f.relative_path}#{tag}"
      end
    end

    def print_warnings(dataset)
      return if dataset.warnings.empty?
      puts ""
      puts "  Warnings (#{dataset.warnings.length}):"
      dataset.warnings.each do |w|
        next unless w[:type] == :stray_file
        rel = File.join(w[:group], File.basename(w[:path]))
        puts "    #{rel} — file directly under group directory (ignored)"
      end
    end

    def pluralize(count, word)
      count == 1 ? word : "#{word}s"
    end
  end
end
