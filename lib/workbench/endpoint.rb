require 'yaml'
require 'fileutils'
require 'active_support/core_ext/string'

module Workbench
  EndpointDir = 'endpoints'

  class Endpoint
    attr_reader :route, :methods

    def initialize(route, methods)
      @route = route
      @methods = methods
    end

    # Load all endpoint files and return an array of Endpoint instances
    def self.all(directory = EndpointDir)
      Dir.glob(File.join(directory, '**', '*.yml')).map do |file|
        route = file_to_route(file, directory)
        yaml = YAML.load_file(file)
        new(route, yaml['methods'] || {})
      end
    end

    # Write or merge an endpoint file. Options:
    #   :path     - HTTP path (e.g. '/tools/linter'); defaults to '/<name>' dasherized
    #   :method   - HTTP verb (default 'POST')
    #   :type     - 'pipeline' or 'task'
    #   :async    - boolean (default false)
    def self.register!(name, options = {}, directory = EndpointDir)
      path    = options.fetch(:path, "/#{name.to_s.dasherize}")
      verb    = options.fetch(:method, 'POST').to_s.upcase
      type    = options.fetch(:type).to_s  # required: 'pipeline' or 'task'
      async   = options.fetch(:async, false)

      file = route_to_file(path, directory)
      FileUtils.mkdir_p(File.dirname(file))

      yaml = File.exist?(file) ? YAML.load_file(file) : {}
      yaml['methods'] ||= {}
      yaml['methods'][verb] = {
        type.to_s => name.to_s,
        'async'        => async,
        'deployed_at'  => Time.now.utc.iso8601
      }

      File.write(file, YAML.dump(yaml))
      new(path, yaml['methods'])
    end

    # Remove a method entry for the given name from its endpoint file.
    # Deletes the file if no methods remain.
    def self.unregister!(name, options = {}, directory = EndpointDir)
      path = options.fetch(:path, "/#{name.to_s.dasherize}")
      verb = options.fetch(:method, nil)&.to_s&.upcase
      file = route_to_file(path, directory)

      return unless File.exist?(file)

      yaml = YAML.load_file(file)
      yaml['methods'] ||= {}

      if verb
        yaml['methods'].delete(verb)
      else
        # Remove any method entry that references this pipeline/task by name
        yaml['methods'].delete_if { |_, v| v['pipeline'] == name.to_s || v['task'] == name.to_s }
      end

      if yaml['methods'].empty?
        File.delete(file)
        prune_empty_dirs(File.dirname(file), directory)
      else
        File.write(file, YAML.dump(yaml))
      end
    end

    # Check all endpoint files for integrity issues. Returns an array of issue
    # hashes, each with at minimum :type and :route. Possible types:
    #
    #   :missing   - a method entry references a pipeline/task that cannot be resolved
    #   :empty     - an endpoint file exists but defines no methods
    #   :duplicate - two files resolve to the same route after dasherization
    #
    # Note: :stale_spec (openapi.yml drift) is checked here once OpenAPIGenerator
    # is introduced in Phase 6.
    def self.detect_issues(directory = EndpointDir)
      issues = []
      files  = Dir.glob(File.join(directory, '**', '*.yml'))

      # :duplicate — two files resolve to the same route
      routes = files.map { |f| [file_to_route(f, directory), f] }
      routes.group_by(&:first).each do |route, pairs|
        if pairs.size > 1
          issues << { type: :duplicate, route: route, files: pairs.map(&:last) }
        end
      end

      files.each do |file|
        route = file_to_route(file, directory)
        yaml  = YAML.load_file(file)
        methods = yaml['methods'] || {}

        # :empty — file exists but has no methods defined
        if methods.empty?
          issues << { type: :empty, route: route, file: file }
          next
        end

        # :missing — method entry references an unknown pipeline or task
        methods.each do |verb, config|
          target = config['pipeline'] || config['task']
          begin
            Workbench.resolve(target)
          rescue ArgumentError
            issues << { type: :missing, route: route, verb: verb, target: target, file: file }
          end
        end
      end

      issues
    end

    # Apply fixes for all resolvable issues returned by detect_issues.
    # Duplicate routes are reported but not auto-fixed (requires human judgment).
    def self.cleanup!(issues, directory = EndpointDir)
      issues.each do |issue|
        case issue[:type]
        when :empty
          File.delete(issue[:file])
          prune_empty_dirs(File.dirname(issue[:file]), directory)

        when :missing
          yaml = YAML.load_file(issue[:file])
          yaml['methods']&.delete(issue[:verb])
          if yaml['methods'].nil? || yaml['methods'].empty?
            File.delete(issue[:file])
            prune_empty_dirs(File.dirname(issue[:file]), directory)
          else
            File.write(issue[:file], YAML.dump(yaml))
          end
        end
        # :duplicate intentionally left for the developer to resolve manually
        # :stale_spec handled in Phase 6
      end
    end

    def self.prune_empty_dirs(dir, directory)
      while dir != File.expand_path(directory)
        break unless Dir.exist?(dir) && Dir.empty?(dir)
        Dir.rmdir(dir)
        dir = File.dirname(dir)
      end
    end
    private_class_method :prune_empty_dirs

    # Convert a file path to its HTTP route.
    # endpoints/code_review.yml       -> /code-review
    # endpoints/tools/linter.yml      -> /tools/linter
    def self.file_to_route(file, directory = EndpointDir)
      relative = file.delete_prefix(directory.chomp('/') + '/')
      segments = relative.delete_suffix('.yml').split('/')
      '/' + segments.map(&:dasherize).join('/')
    end

    # Convert an HTTP route to its endpoint file path.
    # /code-review        -> endpoints/code_review.yml
    # /tools/linter       -> endpoints/tools/linter.yml
    def self.route_to_file(route, directory = EndpointDir)
      segments = route.delete_prefix('/').split('/')
      File.join(directory, *segments) + '.yml'
    end
  end
end
