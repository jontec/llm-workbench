require 'yaml'
require 'workbench'
module Workbench
  
  PipelineDir = "pipelines"
  PipelineExtension = ".y*ml" # yml or yaml

  class Pipeline
    attr_reader :name, :task_list, :tasks, :output, :current_task
    attr_reader :telemetry
    attr_accessor :context
    include Workbench::Telemetry

    class << self
      def telemetry
        @telemetry ||= OpenTelemetry.tracer_provider.tracer("workbench.pipeline_manager")
        @telemetry
      end
    end
    # find by name
    def self.find(name, directory=nil, extension=nil)
      self.telemetry.in_span("pipeline.find") do |span|
        directory ||= PipelineDir
        extension ||= PipelineExtension
        name = File.basename(name, ".*")
        filepath = File.join(directory, name + extension)
        span.add_event "Searching for pipeline: at #{ filepath }"
        matches = Dir.glob(filepath)
        span.add_event "Found pipeline files: #{ matches.inspect }"
        return if matches.empty?
        return self.new(matches.sort.first)
      end
    end

    # find by name or path
    def self.find_by_name_or_path(name_or_path)
      self.telemetry.in_span("pipeline.find_by_name_or_path") do |span|
        path = File.dirname(name_or_path)
        path = nil if path == "."
        extension = File.extname(name_or_path)
        name = File.basename(name_or_path, extension)
        puts "Searching for pipeline: #{ name } in #{ path }"
        self.find(name, path)
      end
    end

    def self.list(directory=PipelineDir)
      Dir.glob(File.join(PipelineDir, PipelineExtension))
    end

    def initialize(filepath, options={})
      path = File.dirname(filepath)
      matching_files = Dir.glob(filepath)
      raise "Cannot load pipeline from #{ filepath } -- file does not exist" if matching_files.empty?
      initialize_telemetry
      load_from_file(matching_files.sort.first) # if there's a pipeline.yml AND pipeline.yaml, we'll take the latter
      @context = {}
    end

    def run
      @telemetry.in_span("pipeline.run") do |span|
        @output = {}
        @task_list.each do |task|
          @current_task = task
          @telemetry.in_span("task.run", attributes: { 'task_name' => task.name.to_s }) do |task_span|
            task.run
          end
          @output[task] = task.outputs
          @context.merge!(task.pipeline_outputs)
          span.add_event("task_completed", attributes: {
            "outputs" => task.outputs.inspect,
            "current_pipeline_context" => @context.inspect
          })
          # puts "Task #{ task.name } completed with outputs: #{ task.outputs.inspect }"
          # puts "Current pipeline context: #{ @context.inspect }"
        end
      end
    end
  
    # want two methods
    # #get_output(:task_name)
    # #get_last_output(:task_name)
    def get_output
      # TODO: We can actually make do without this for now
      # see #fetch_previous_output
      # more flexible/better pattern to just use the pipeline context to get the key needed
    end

    def prior_task(task=current_task)
      @task_list[@task_list.index(task) - 1]
    end
  
    def fetch_previous_output(key, task=@current_task)
      @tasks[self.prior_task].outputs[key]
    end

    protected

    def load_from_file(path_to_pipeline)
      @telemetry.in_span("load_pipeline") do |span|
        yaml = YAML.load_file(path_to_pipeline)
        @name = yaml["name"]
        index_tasks(yaml["tasks"])
      end
    end

    # TODO: we also want control flow directives inside the pipeline definition
    # e.g. success, failure, conditional (case on a specific value) as well as for each
    # parallel execution
    def index_tasks(tasks)
      open_span("index_tasks")
      Task.load_default_tasks_once
      @task_list = []
      @tasks = {}
      tasks.each do |t|
        task_name = t["name"].to_sym
        task_class = Task.find(task_name)
        raise "Task #{ task_name } not found" unless task_class
        task = task_class.new(self, t)
        @task_list << task # the task list defines a sequential order of tasks, preserved in this array
        # @tasks[task] will be set when run
      end
      close_span("index_tasks")
    end

    def initialize_telemetry
      @telemetry = OpenTelemetry.tracer_provider.tracer("workbench.pipeline")
    end
  end
end