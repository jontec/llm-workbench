require "workbench/version"
require "workbench/eval_file"
require "workbench/eval_case"
require "workbench/dataset"
require "workbench/eval"
require "workbench/eval_runner"
require "workbench/eval_result_writer"
require "workbench/open_telemetry/exporters"
require "workbench/telemetry"
require "workbench/llm_provider"
require "workbench/prompt"
require "workbench/task"
require "workbench/pipeline"
require "workbench/schema"
require "workbench/config"
require "workbench/endpoint"
require "workbench/input_validator"
require "workbench/server"
require "workbench/cli"

module Workbench
  # Resolves a name to a pipeline or task, returning a hash with :name and :type.
  # Raises ArgumentError if neither can be found.
  def self.resolve(name)
    Task.load_default_tasks_once

    pipeline = Pipeline.find(name.to_s)
    return { name: name.to_s, type: 'pipeline' } if pipeline

    begin
      Task.find(name)
      return { name: name.to_s, type: 'task' }
    rescue NameError
      # not a task
    end

    raise ArgumentError, "Cannot resolve '#{name}' as a known pipeline or task"
  end
end