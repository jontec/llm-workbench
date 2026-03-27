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

    desc "serve", "Start the Workbench HTTP server"
    option :port,   type: :numeric, desc: "Port to bind", default: nil
    option :host,   type: :string,  desc: "Host to bind", default: nil
    option :config, type: :string,  desc: "Path to workbench.yml", default: 'workbench.yml'
    def serve
      config = Config.load(options[:config])

      unless config.server_api_key
        puts "Error: server.api_key must be set in #{options[:config]} before starting the server."
        puts "Set it to a string value or an environment variable reference (e.g. \$API_KEY)."
        exit 1
      end

      port = options[:port] || config.server_port
      host = options[:host] || config.server_host

      endpoints = Endpoint.all
      if endpoints.empty?
        puts "Warning: no endpoints found. Deploy a pipeline first with `workbench deploy <name>`."
      end

      Server.workbench_config    = config
      Server.workbench_endpoints = endpoints

      puts "Starting Workbench server on #{host}:#{port}"
      puts "  #{endpoints.size} endpoint(s) loaded"
      puts "  Base path: #{config.server_base_path || '(none)'}"

      require 'rackup/handler/webrick'
      Rackup::Handler::WEBrick.run(Server, Host: host, Port: port)
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

    desc "endpoints", "List, verify, or repair deployed endpoints"
    option :check,   type: :boolean, desc: "Check integrity of all endpoint files; exits non-zero if issues found"
    option :cleanup, type: :boolean, desc: "Describe issues and proposed fixes, then prompt before applying"
    def endpoints
      if options[:check]
        run_check
      elsif options[:cleanup]
        run_cleanup
      else
        list_endpoints
      end
    end

    private

    def list_endpoints
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

    def run_check
      issues = Endpoint.detect_issues
      if issues.empty?
        puts "All endpoints OK."
        return
      end

      issues.each { |i| puts format_issue(i) }
      exit 1
    end

    def run_cleanup
      issues = Endpoint.detect_issues
      if issues.empty?
        puts "All endpoints OK. Nothing to clean up."
        return
      end

      auto_fixable = issues.reject { |i| i[:type] == :duplicate }
      manual       = issues.select { |i| i[:type] == :duplicate }

      puts "Found #{issues.size} issue(s):\n\n"
      issues.each { |i| puts "  #{format_issue(i)}" }

      unless auto_fixable.empty?
        puts "\nProposed fixes:"
        auto_fixable.each { |i| puts "  #{format_fix(i)}" }

        if yes?("\nApply #{auto_fixable.size} fix(es)?")
          Endpoint.cleanup!(auto_fixable)
          puts "Done."
        else
          puts "Aborted — no changes made."
        end
      end

      unless manual.empty?
        puts "\nThe following duplicate route(s) require manual resolution:"
        manual.each { |i| puts "  #{format_issue(i)}" }
      end
    end

    def format_issue(issue)
      case issue[:type]
      when :missing
        "[missing]   #{issue[:verb]} #{issue[:route]} → '#{issue[:target]}' could not be resolved"
      when :empty
        "[empty]     #{issue[:route]} — #{issue[:file]} has no methods defined"
      when :duplicate
        "[duplicate] #{issue[:route]} — matched by: #{issue[:files].join(', ')}"
      when :stale_spec
        "[stale-spec] openapi.yml is out of sync with current endpoint definitions"
      end
    end

    def format_fix(issue)
      case issue[:type]
      when :missing
        "Remove #{issue[:verb]} entry from #{issue[:file]}#{' (and delete file if empty)' if would_empty_file?(issue)}"
      when :empty
        "Delete #{issue[:file]}"
      end
    end

    def would_empty_file?(issue)
      return false unless File.exist?(issue[:file])
      yaml = YAML.load_file(issue[:file])
      (yaml['methods'] || {}).size <= 1
    end
  end
end