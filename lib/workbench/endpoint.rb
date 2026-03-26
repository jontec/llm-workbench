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
        # Remove empty parent directories up to the endpoint dir
        dir = File.dirname(file)
        while dir != File.expand_path(directory)
          break unless Dir.empty?(dir)
          Dir.rmdir(dir)
          dir = File.dirname(dir)
        end
      else
        File.write(file, YAML.dump(yaml))
      end
    end

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
