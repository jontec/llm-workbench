require 'json'
require 'json-schema'

module Workbench
  SchemaDir = "schema"
  SchemaExtension = ".json"

  class Schema
    attr_reader :file, :path, :name, :version, :definition
    class << self
      def telemetry
        @telemetry ||= OpenTelemetry.tracer_provider.tracer("workbench.schema_manager")
        @telemetry
      end
    end

    # Find a schema file by name (symbol or string) and optional version
    def self.find(name, version=nil)
      base = name.to_s
      search_pattern = base
      if version
        search_pattern += ".v#{version}"
      else
        search_pattern += "*"
      end

      search_pattern = File.join(SchemaDir, search_pattern + SchemaExtension)
  
      puts "Searching for schema file with pattern: #{ search_pattern }"
  
      matches = Dir.glob(search_pattern)
      return nil if matches.empty?
      selected = matches.sort.last
      self.new(selected)
    end

    def initialize(path_to_file)
      @path = path_to_file
      @file = File.open(path_to_file)
      @name = File.basename(path_to_file, ".json")
      @version = @name[/\.v(\d+)/, 1]
      @definition = JSON.parse(@file.read)
      @file.rewind
    end

    # Returns the raw JSON schema as a Ruby hash
    def to_h
      @definition
    end

    # Returns the schema wrapped for OpenAI API use
    def format_for_api(provider=nil)
      {
        format: {
          type: "json_schema",
          name: @name,
          schema: @definition,
          strict: true
        }
      }
    end

    # Checks if the given JSON (string or hash) conforms to this schema
    def validates?(input)
      json = parse_json_string_or_object(input)
      JSON::Validator.validate(@definition, json)
    end
  
    def validate_and_parse(input)
      json = parse_json_string_or_object(input)
      if validates?(json)
        json
      else
        raise JSON::Schema::ValidationError, "JSON does not conform to schema #{@name}"
      end
    end
  
    protected
    def parse_json_string_or_object(json_string_or_object)
      if json_string_or_object.is_a?(String)
        JSON.parse(json_string_or_object)
      else
        json_string_or_object
      end
    end
  end
end