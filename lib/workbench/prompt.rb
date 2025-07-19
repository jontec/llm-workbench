require 'active_support/core_ext/string'
module Workbench
  PromptDir = "prompts"
  class Prompt
    attr_reader :file
    class << self
      def telemetry
        @telemetry ||= OpenTelemetry.tracer_provider.tracer("workbench.prompt_manager")
        @telemetry
      end
    end
    # TODO: a task can be opinionated and provide a default set of models to search against
    # when that's the case, we should dynamically take that into account, since a prompt belongs to a task (usually)
    # usage
    # Prompt.find(:parse_itinerary_email)
    # Prompt.find("parse_itinerary_email")
    # Prompt.find("parse_itinerary_email", 1, "openai", "gpt-4")
    # Prompt.find("parse_itinerary_email")
    # it finds the relevant one based on the file system sort order
    # LLMProvider provides the relevant sort order
    def self.find(path_to_file_or_class_name, *args)
      self.telemetry.in_span("prompt.find") do |span|
        if path_to_file_or_class_name.is_a?(Class)
          path_to_file = path_to_file_or_class_name.to_s.underscore
        else
          path_to_file = path_to_file_or_class_name
        end
    
        path, filename = File.dirname(path_to_file), File.basename(path_to_file)
        unless File.absolute_path?(path)
          # if the path is not absolute, we will assume that it's relative to the prompts directory
          path = File.join(PromptDir, path == "." ? "" : path)
        end

        span.add_event "Searching for prompt file in #{ path } with filename #{ filename }"
        file_extension = File.extname(filename) if filename
        version, provider, model = *args unless args.empty?
        
        # if file_extension is provided, we'll try to locate the exact prompt
        # else, if it's blank, then we need to build a search path to find the best matching prompt
        if file_extension.empty?
          file_extension = ".prompt.erb"
          # ".v1.*.prompt.erb"
          # ".v1.*"
          # ".v1.*.*.prompt.erb"
          search_path = ""
    
          # build the search path based on the args
          if version
            search_path = ".v#{ version }"
          else
            search_path = "*"
          end

          if model
            # we will assume that the model is selected only with a provider
            # otherwise, we will have to implement a lookup for the provider from the model name (which is usually unique, but extra work)
            search_path += ".#{ provider }.#{ model }"
          elsif provider
            search_path += ".#{ provider }*"
          elsif version
            search_path += "*"
          end
    
          # Add the final file extension
          search_path += file_extension
    
          search_path = filename + search_path
        else
          # if file_extension is provided, we will use it to search for the prompt file directly
          search_path = filename + file_extension
        end

        span.add_event "Searching for prompt file with base search path: #{ search_path }"

        search_path = File.join(path, search_path)

        span.add_event "Searching for prompt file with full search path: #{ search_path }"
        
        matches = Dir.glob(search_path)
        span.add_event "Found prompt files: #{ matches.inspect }"

        unless matches.empty?
          # sort the matches to find the highest (appropriate for version)
          selected_prompt_filename = matches.sort.last
          self.new(selected_prompt_filename)
        else
          nil
        end
      end
    end

    def initialize(path_to_file)
      load(path_to_file)
      raise "Prompt file not found: #{ path_to_file }" unless @file
    end

    def render(*args)
      # TODO: update this method to process with ERB
      @file.read
    end
    
    protected
    def load(path_to_file)
      @file = File.open(path_to_file) if File.exist?(path_to_file)
    end
  end
end