require 'active_support/core_ext/string'
module Workbench
  TaskDir = 'tasks'
  class Task
    include Workbench::Telemetry
  
    class << self
      attr_reader :input_definitions, :output_definitions

      def input(name, **opts)
        @input_definitions ||= {}
        @input_definitions[name.to_sym] = opts
      end

      def output(name, **opts)
        @output_definitions ||= {}
        @output_definitions[name.to_sym] = opts
      end
    
      def telemetry
        @telemetry ||= OpenTelemetry.tracer_provider.tracer("workbench.task_manager")
        @telemetry
      end
    end

    attr_accessor :inputs
    attr_reader :outputs, :config, :pipeline
    @loaded_roots = {}

    def self.task_dir=(task_dir)
      @task_dir = task_dir
      self.load_tasks_once(@task_dir)
    end

    def self.task_dir
      @task_dir
    end

    def initialize(pipeline=nil, task_config={})
      # TODO: handle task_config, including using foreach and model/provider/version directives
      @pipeline = pipeline
      initialize_telemetry
      load_prompt
    end

    # Entry point for task execution
    def run
      raise NotImplementedError, "Subclasses must implement the run method"
    end

    # Allows logging to pipeline-level logger if available
    # QUESTION: Oops, what did I say was the behavior here. Do logs only exist at the pipeline level?
    def log_to_pipeline(message)
      @pipeline.logger.info("[#{name}] #{message}")
    end

    # Retrieve input from previous task
    def fetch_input(key)
      raise "Undefined input requested: #{ key }" unless self.class.input_definitions.key?(key)
  
      inputs&.[](key) || @pipeline.context[key]
    end

    # Store a value to task outputs
    def store_output(key, value)
      @outputs ||= {}
      @outputs[key] = value
    end

    # Outputs are automatically merged into the default pipeline context unless exempted
    def pipeline_outputs
      filtered_outputs = @outputs&.filter { |k, v| self.class.output_definitions[k][:export].nil? }
      return filtered_outputs || {}
    end

    # what behavior do I want
    # a.) default behavior => look in tasks/
    # b.) override behavior => look in #task_dir, but not anywhere else unless asked
    # c.) one-off behavior => look in #task_dir unless it's already been looked at
  
    def self.load_default_tasks_once
      self.load_tasks_once(@task_dir)
    end
  
    def self.load_tasks_once(task_dir=nil)
      if task_dir && File.absolute_path?(task_dir)
        search_path = File.join(task_dir)
      else
        search_path = task_dir || TaskDir
      end
      return if @loaded_roots[search_path]
      task_files = Dir.glob(File.join(search_path, "*.rb")).sort
      task_files.each do |file|
        require_relative File.join(Dir.pwd, file)
      end
    end

    def self.reload_tasks!
      roots = @loaded_roots
      @loaded_roots = {}
      roots.each { |r| self.load_tasks_once(r) }
    end

    def self.find(name)
      Object.const_get(name.to_s.camelize)
    end

    def name
      self.class.to_s.underscore.to_sym
    end

    protected
    def load_prompt
      @prompt = Prompt.find(self.class)
    end
    def initialize_telemetry
      if @pipeline
        @telemetry = @pipeline.telemetry
      else
        @telemetry = OpenTelemetry.tracer_provider.tracer("workbench.task")
      end
    end
  end
end