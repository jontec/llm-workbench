require 'yaml'

module Workbench
  class Config
    DEFAULTS = {
      'server' => {
        'port'      => 9292,
        'host'      => '0.0.0.0',
        'base_path' => nil,
        'api_key'   => nil,
        'openapi'   => true
      },
      'project' => {
        'name'         => nil,
        'task_dir'     => 'tasks',
        'pipeline_dir' => 'pipelines'
      },
      'database' => {
        'adapter'        => nil,
        'url'            => nil,
        'migrations_dir' => 'db/migrate'
      }
    }.freeze

    def self.load(path = 'workbench.yml')
      yaml = File.exist?(path) ? YAML.load_file(path) || {} : {}
      merged = deep_merge(DEFAULTS, yaml)
      new(merged)
    end

    def initialize(data = {})
      @data = deep_merge(DEFAULTS, data)
    end

    # Server
    def server_port      = @data.dig('server', 'port')
    def server_host      = @data.dig('server', 'host')
    def server_base_path = @data.dig('server', 'base_path')
    def server_openapi   = @data.dig('server', 'openapi') != false

    def server_api_key
      key = @data.dig('server', 'api_key')
      return nil if key.nil?
      key.to_s.start_with?('$') ? ENV[key.to_s[1..]] : key.to_s
    end

    # Project
    def project_name         = @data.dig('project', 'name')
    def project_task_dir     = @data.dig('project', 'task_dir')
    def project_pipeline_dir = @data.dig('project', 'pipeline_dir')

    # Database (parsed but unused until future database feature)
    def database_adapter        = @data.dig('database', 'adapter')
    def database_url            = @data.dig('database', 'url')
    def database_migrations_dir = @data.dig('database', 'migrations_dir')

    private

    def self.deep_merge(base, override)
      base.merge(override) do |_, base_val, override_val|
        if base_val.is_a?(Hash) && override_val.is_a?(Hash)
          deep_merge(base_val, override_val)
        else
          override_val.nil? ? base_val : override_val
        end
      end
    end

    def deep_merge(base, override)
      self.class.deep_merge(base, override)
    end
  end
end
