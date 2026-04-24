require 'yaml'
require 'pathname'

module Workbench
  DatasetDir  = 'datasets'
  FixturesDir = 'fixtures'

  class Dataset
    DEFAULT_JUNK = %w[.DS_Store Thumbs.db desktop.ini].freeze

    attr_reader :name, :path, :include_patterns, :ignore_patterns, :sort,
                :directory_mode, :case_config, :group_config, :warnings

    def self.find(name)
      yaml_path = File.join(DatasetDir, "#{name}.yml")
      raise ArgumentError, "Dataset '#{name}' not found at #{yaml_path}" unless File.exist?(yaml_path)
      new(yaml_path)
    end

    def initialize(yaml_path)
      data = YAML.load_file(yaml_path) || {}
      @name             = data['name'] || File.basename(yaml_path, '.*')
      @path             = data['path'] || @name
      @include_patterns = Array(data['include'] || '**/*')
      @ignore_patterns  = Array(data['ignore'])
      @sort             = data['sort'] || 'asc'
      @directory_mode   = data['directory']   # nil, 'case', or 'group'
      @case_config      = data['case']  || {}
      @group_config     = data['group'] || {}
      @warnings         = []
    end

    def cases
      base = File.expand_path(File.join(FixturesDir, @path))
      raise ArgumentError, "Dataset fixture path '#{base}' does not exist" unless File.exist?(base)

      @warnings = []
      result = case @directory_mode
               when 'case'  then discover_case_mode(base)
               when 'group' then discover_group_mode(base)
               else              discover_default(base)
               end

      result = result.map { |c| apply_hints(c) }
      raise ArgumentError, "Dataset '#{@name}' discovered zero cases" if result.empty?
      result
    end

    private

    # -------------------------------------------------------------------------
    # Discovery modes
    # -------------------------------------------------------------------------

    # Default: dirs-as-cases if any dirs present, else files-as-cases.
    def discover_default(base)
      children = direct_children(base)
      dirs  = children.select { |e| File.directory?(e) }.reject { |d| empty_dir?(d) }
      files = children.select { |e| File.file?(e) }.select { |f| include_file?(f, base) }

      if dirs.any?
        dirs.map { |d| case_from_dir(d, base) }
      else
        files.map { |f| case_from_file(f, base) }
      end
    end

    # Explicit: immediate child dirs are cases; sibling files ignored.
    def discover_case_mode(base)
      direct_children(base)
        .select  { |e| File.directory?(e) }
        .reject  { |d| empty_dir?(d) }
        .map     { |d| case_from_dir(d, base) }
    end

    # Explicit: immediate child dirs are groups; default discovery within each.
    def discover_group_mode(base)
      group_dirs = direct_children(base).select { |e| File.directory?(e) }

      group_dirs.flat_map do |group_dir|
        group_name = File.basename(group_dir)

        # Files directly under the group dir are excluded — collect as warnings.
        group_children = direct_children(group_dir)
        stray_files = group_children.select { |e| File.file?(e) }
        stray_files.each do |f|
          @warnings << { type: :stray_file, group: group_name, path: f }
        end

        # Apply group-level include/ignore to filter group children.
        filtered_dirs  = group_children
          .select { |e| File.directory?(e) }
          .reject { |d| empty_dir_with_config?(d, group_config_ignore_patterns) }
          .select { |d| include_in_group?(d, group_dir) }

        filtered_files = group_children
          .select { |e| File.file?(e) }
          .select { |f| include_in_group?(f, group_dir) }

        # Within each group, apply default discovery.
        group_cases = if filtered_dirs.any?
          filtered_dirs.map { |d| case_from_dir(d, group_dir, group_name: group_name) }
        else
          filtered_files
            .select { |f| include_file?(f, group_dir) }
            .map    { |f| case_from_file(f, group_dir, group_name: group_name) }
        end

        group_cases
      end
    end

    # -------------------------------------------------------------------------
    # Case construction
    # -------------------------------------------------------------------------

    def case_from_dir(dir_path, dataset_root, group_name: nil)
      id    = File.basename(dir_path)
      files = collect_files(dir_path, dataset_root)
      EvalCase.new(id: id, root_path: dir_path, files: files, group_name: group_name)
    end

    def case_from_file(file_path, dataset_root, group_name: nil)
      id   = File.basename(file_path, '.*')
      file = EvalFile.new(file_path, dataset_root)
      EvalCase.new(id: id, root_path: dataset_root, files: [file], group_name: group_name)
    end

    # -------------------------------------------------------------------------
    # Hints: classify case files into inputs / outputs
    # -------------------------------------------------------------------------

    def apply_hints(eval_case)
      input_patterns  = Array(@case_config['inputs'])
      output_patterns = Array(@case_config['outputs'])
      return eval_case if input_patterns.empty? && output_patterns.empty?

      inputs  = eval_case.files.select { |f| matches_case_hint?(f, input_patterns,  eval_case.root_path) }
      outputs = eval_case.files.select { |f| matches_case_hint?(f, output_patterns, eval_case.root_path) }

      EvalCase.new(
        id:         eval_case.id,
        group_name: eval_case.group_name,
        root_path:  eval_case.root_path,
        files:      eval_case.files,
        inputs:     inputs,
        outputs:    outputs
      )
    end

    def matches_case_hint?(eval_file, patterns, root_path)
      return false if patterns.empty?
      rel = eval_file.relative_path
      patterns.any? { |p| File.fnmatch(p, rel, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
    end

    # -------------------------------------------------------------------------
    # File collection
    # -------------------------------------------------------------------------

    def collect_files(dir_path, dataset_root)
      Dir.glob(File.join(dir_path, '**', '*'), File::FNM_DOTMATCH)
         .select { |f| File.file?(f) }
         .reject { |f| hidden?(File.basename(f)) || junk?(File.basename(f)) }
         .select { |f| include_file?(f, dataset_root) }
         .select { |f| include_case_file?(f, dir_path) }
         .sort
         .map    { |f| EvalFile.new(f, dir_path) }
    end

    # -------------------------------------------------------------------------
    # Filtering helpers
    # -------------------------------------------------------------------------

    def include_file?(file_path, base)
      rel = Pathname.new(file_path).relative_path_from(Pathname.new(base)).to_s
      matches_any?(rel, @include_patterns) && !matches_any?(rel, @ignore_patterns)
    end

    # Case-level include/ignore layered on top of top-level patterns.
    def include_case_file?(file_path, case_root)
      case_include = Array(@case_config['include'])
      case_ignore  = Array(@case_config['ignore'])
      return true if case_include.empty? && case_ignore.empty?

      rel = Pathname.new(file_path).relative_path_from(Pathname.new(case_root)).to_s
      (case_include.empty? || matches_any?(rel, case_include)) &&
        !matches_any?(rel, case_ignore)
    end

    def include_in_group?(path, group_root)
      group_include = Array(@group_config['include'])
      group_ignore  = Array(@group_config['ignore'])
      return true if group_include.empty? && group_ignore.empty?

      rel = Pathname.new(path).relative_path_from(Pathname.new(group_root)).to_s
      (group_include.empty? || matches_any?(rel, group_include)) &&
        !matches_any?(rel, group_ignore)
    end

    def group_config_ignore_patterns
      Array(@group_config['ignore'])
    end

    def matches_any?(rel_path, patterns)
      patterns.any? { |p| File.fnmatch(p, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
    end

    # -------------------------------------------------------------------------
    # Directory helpers
    # -------------------------------------------------------------------------

    def direct_children(base)
      entries = Dir.entries(base).reject { |e| %w[. ..].include?(e) || hidden?(e) || junk?(e) }
      sorted  = @sort == 'desc' ? entries.sort.reverse : entries.sort
      sorted.map { |e| File.join(base, e) }
    end

    def hidden?(name)
      name.start_with?('.')
    end

    def junk?(name)
      DEFAULT_JUNK.include?(name)
    end

    def empty_dir?(dir)
      Dir.glob(File.join(dir, '**', '*')).none? { |f| File.file?(f) }
    end

    def empty_dir_with_config?(dir, ignore_patterns)
      files = Dir.glob(File.join(dir, '**', '*')).select { |f| File.file?(f) }
      return true if files.empty?
      return false if ignore_patterns.empty?
      files.all? do |f|
        rel = Pathname.new(f).relative_path_from(Pathname.new(dir)).to_s
        matches_any?(rel, ignore_patterns)
      end
    end
  end
end
