require "thor"

module Workbench
  class CLI < Thor
    desc "start", "start <pipeline> or start /path/to/pipeline[.y*ml] Run the specified pipeline using tasks from ./tasks"
    option :verbose, type: :boolean
    option :input, type: :hash, desc: "Input values for the pipeline"
    def start(pipeline_or_path_to_file)
      # default path will be pipelines/ directory from the project root
      # if this were built in rails, we'd always be able to find the application root directory
      # should we have a workbench config file to flag where the approot should be?
      # usage should be 
      # thinking: pipelines are declared in YAML, but tasks are defined in Ruby
      # when we need to look up tasks we can just load all of them from memory (if we've loaded them already)
      puts "Verbose mode ON" if options[:verbose]
      Task.task_dir = options[:task_dir] if options[:task_dir]
      pipeline = Pipeline.find_by_name_or_path(pipeline_or_path_to_file)
      if options[:input]
        pipeline.context.merge!(options[:input].deep_symbolize_keys)
      end
      puts "Running pipeline: #{ pipeline.name }"
      pipeline.run
    end

    desc "list", "List known pipelines"
    def list
      puts Pipeline.list
    end
  end
end