require 'yaml'
require 'pathname'

module Workbench
  DatasetDir  = 'datasets'
  FixturesDir = 'fixtures'

  class Dataset
    DEFAULT_JUNK = %w[.DS_Store Thumbs.db desktop.ini].freeze

    attr_reader :name, :path, :include_patterns, :ignore_patterns, :sort

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
    end

    def cases
      base = File.expand_path(File.join(FixturesDir, @path))
      raise ArgumentError, "Dataset fixture path '#{base}' does not exist" unless File.exist?(base)

      result = discover(base)
      raise ArgumentError, "Dataset '#{@name}' discovered zero cases" if result.empty?
      result
    end

    private

    def discover(base)
      children = direct_children(base)
      dirs  = children.select { |e| File.directory?(e) }.reject { |d| empty_dir?(d) }
      files = children.select { |e| File.file?(e) }.select { |f| include_file?(f, base) }

      if dirs.any?
        dirs.map { |d| case_from_dir(d, base) }
      else
        files.map { |f| case_from_file(f, base) }
      end
    end

    def direct_children(base)
      entries = Dir.entries(base).reject { |e| %w[. ..].include?(e) || hidden?(e) || junk?(e) }
      sorted  = @sort == 'desc' ? entries.sort.reverse : entries.sort
      sorted.map { |e| File.join(base, e) }
    end

    def case_from_dir(dir_path, dataset_root)
      id    = File.basename(dir_path)
      files = collect_files(dir_path, dataset_root)
      EvalCase.new(id: id, root_path: dir_path, files: files)
    end

    def case_from_file(file_path, dataset_root)
      id   = File.basename(file_path, '.*')
      file = EvalFile.new(file_path, dataset_root)
      EvalCase.new(id: id, root_path: dataset_root, files: [file])
    end

    def collect_files(dir_path, dataset_root)
      Dir.glob(File.join(dir_path, '**', '*'), File::FNM_DOTMATCH)
         .select { |f| File.file?(f) }
         .reject { |f| hidden?(File.basename(f)) || junk?(File.basename(f)) }
         .select { |f| include_file?(f, dataset_root) }
         .sort
         .map    { |f| EvalFile.new(f, dir_path) }
    end

    def include_file?(file_path, base)
      rel = Pathname.new(file_path).relative_path_from(Pathname.new(base)).to_s
      matches_any?(rel, @include_patterns) && !matches_any?(rel, @ignore_patterns)
    end

    def matches_any?(rel_path, patterns)
      patterns.any? { |p| File.fnmatch(p, rel_path, File::FNM_PATHNAME | File::FNM_DOTMATCH) }
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
  end
end
