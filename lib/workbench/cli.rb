require "thor"

module Workbench
  class CLI < Thor
    desc "start", "start <pipeline> or start /path/to/pipeline[.y*ml] Run the specified pipeline or task"
    option :verbose, type: :boolean
    option :input, type: :hash, desc: "Input values for the pipeline"
    def start(pipeline_name_or_path_or_task)
      # default path will be pipelines/ directory from the project root
      # if this were built in rails, we'd always be able to find the application root directory
      # should we have a workbench config file to flag where the approot should be?
      # usage should be 
      # thinking: pipelines are declared in YAML, but tasks are defined in Ruby
      # when we need to look up tasks we can just load all of them from memory (if we've loaded them already)
      puts "Verbose mode ON" if options[:verbose]
      Task.task_dir = options[:task_dir] if options[:task_dir]
      pipeline = Pipeline.find_by_name_or_path(pipeline_name_or_path_or_task)
      unless pipeline
        pipeline = Pipeline.lambda([pipeline_name_or_path_or_task])
      end
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

    desc "deploy NAME", "Deploy a pipeline or task as an HTTP endpoint"
    option :path,    aliases: '-p', type: :string,  desc: "HTTP path for the endpoint (default: /<name> dasherized)"
    option :method,  aliases: '-m', type: :string,  desc: "HTTP verb",    default: 'POST'
    option :async,                  type: :boolean, desc: "Run pipeline in background and return a run_id", default: false
    option :dry_run,                type: :boolean, desc: "Preview without writing", default: false
    def deploy(name)
      resolved = Workbench.resolve(name)
      path     = options[:path] || "/#{name.to_s.dasherize}"

      if options[:dry_run]
        file = Endpoint.route_to_file(path)
        puts "Would write: #{file}"
        puts "  #{options[:method].upcase} #{path} → #{resolved[:type]}: #{resolved[:name]}"
        return
      end

      endpoint = Endpoint.register!(name, {
        path:   path,
        method: options[:method],
        type:   resolved[:type],
        async:  options[:async]
      })

      puts "Deployed: #{options[:method].upcase} #{endpoint.route} → #{resolved[:type]}: #{resolved[:name]}"
      puts "  File: #{Endpoint.route_to_file(endpoint.route)}"
      # TODO Phase 6: regenerate openapi.yml here
    end

    desc "undeploy NAME", "Remove a deployed endpoint"
    option :path,   aliases: '-p', type: :string, desc: "HTTP path of the endpoint to remove (default: /<name> dasherized)"
    option :method, aliases: '-m', type: :string, desc: "Remove only this HTTP verb (default: remove all methods for this name)"
    def undeploy(name)
      path = options[:path] || "/#{name.to_s.dasherize}"
      Endpoint.unregister!(name, { path: path, method: options[:method] })
      puts "Undeployed: #{path}#{" [#{options[:method].upcase}]" if options[:method]}"
      # TODO Phase 6: regenerate openapi.yml here
    end

    desc "endpoints", "List all deployed endpoints"
    def endpoints
      all = Endpoint.all
      if all.empty?
        puts "No endpoints deployed. Run `workbench deploy <name>` to get started."
        return
      end

      all.each do |endpoint|
        endpoint.methods.each do |verb, config|
          type   = config['pipeline'] ? 'pipeline' : 'task'
          target = config[type]
          async  = config['async'] ? ' (async)' : ''
          puts "%-6s %s → %s: %s%s" % [verb, endpoint.route, type, target, async]
        end
      end
    end
  end
end