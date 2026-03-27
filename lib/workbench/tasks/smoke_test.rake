require 'tmpdir'
require 'net/http'
require 'json'
require 'yaml'
require 'fileutils'
require 'open3'

namespace :workbench do
  desc 'End-to-end smoke test. Usage: rake workbench:smoke or rake "workbench:smoke[pipeline_name,api_key]"'
  task :smoke, [:pipeline, :api_key] do |_, args|
    if args[:pipeline] && args[:api_key].nil?
      abort "Usage: rake \"workbench:smoke[pipeline_name,api_key]\" — api_key is required when testing a real pipeline"
    end

    runner = Workbench::SmokeRunner.new(
      pipeline: args[:pipeline],
      api_key:  args[:api_key]
    )
    exit 1 unless runner.run
  end
end

module Workbench
  class SmokeRunner
    SMOKE_PORT = 19292
    BOOT_TIMEOUT = 10  # seconds to wait for server

    GEM_ROOT      = File.expand_path('../../..', __dir__)
    WORKBENCH_BIN = File.join(GEM_ROOT, 'bin', 'workbench')
    WORKBENCH_LIB = File.join(GEM_ROOT, 'lib')

    # Ensure all subprocesses find the gem's Gemfile regardless of working
    # directory — critical when running CLI commands inside a tmpdir fixture.
    BUNDLE_ENV = { 'BUNDLE_GEMFILE' => File.join(GEM_ROOT, 'Gemfile') }.freeze

    def initialize(pipeline: nil, api_key: nil)
      @custom_pipeline = pipeline
      @api_key = api_key || 'smoke-test-key'
      @passed  = 0
      @failed  = 0
    end

    def run
      if @custom_pipeline
        run_checks(Dir.pwd, @custom_pipeline, input: {})
      else
        Dir.mktmpdir('workbench_smoke') do |dir|
          setup_fixture(dir)
          run_checks(dir, 'greet', input: { name: 'World' })
        end
      end

      puts "\n#{'─' * 50}"
      puts "#{@passed + @failed} checks: #{@passed} passed, #{@failed} failed"
      @failed.zero?
    end

    private

    # ---------------------------------------------------------------------------
    # Test flow
    # ---------------------------------------------------------------------------

    def run_checks(dir, pipeline_name, input:)
      route = pipeline_name.gsub('_', '-')
      puts "\nWorkbench smoke test — pipeline: #{pipeline_name}"
      puts '─' * 50

      check("deploy writes endpoint file") do
        cli_run("deploy #{pipeline_name}", dir: dir)
        File.exist?(File.join(dir, 'endpoints', "#{route}.yml"))
      end

      check("endpoints command lists the route") do
        out, = Open3.capture2(BUNDLE_ENV, "#{workbench_cmd} endpoints", chdir: dir)
        out.include?(route)
      end

      with_server(dir) do
        check("valid request returns 200 with outputs") do
          res = post("/#{route}", input, auth: @api_key)
          res.code == '200' && JSON.parse(res.body).key?('outputs')
        end

        # Only run input validation check in fixture mode — custom pipelines
        # may have all-optional inputs, making an empty body valid.
        unless @custom_pipeline
          check("missing required input returns 422") do
            res = post("/#{route}", {}, auth: @api_key)
            res.code == '422' && JSON.parse(res.body)['missing']&.include?('name')
          end
        end

        check("missing API key returns 401") do
          res = post("/#{route}", input)
          res.code == '401'
        end

        check("wrong API key returns 401") do
          res = post("/#{route}", input, auth: 'wrong-key')
          res.code == '401'
        end

        check("unknown route returns 404") do
          res = post('/nonexistent-route', input, auth: @api_key)
          res.code == '404'
        end
      end

      check("undeploy removes endpoint file") do
        cli_run("undeploy #{pipeline_name}", dir: dir)
        !File.exist?(File.join(dir, 'endpoints', "#{route}.yml"))
      end

      # Restart server with no endpoints to verify the undeployed route is gone.
      with_server(dir) do
        check("undeployed route returns 404") do
          res = post("/#{route}", input, auth: @api_key)
          res.code == '404'
        end
      end
    end

    # ---------------------------------------------------------------------------
    # Fixture
    # ---------------------------------------------------------------------------

    def setup_fixture(dir)
      FileUtils.mkdir_p(File.join(dir, 'tasks'))
      FileUtils.mkdir_p(File.join(dir, 'pipelines'))

      File.write(File.join(dir, 'tasks', 'greet.rb'), <<~RUBY)
        class Greet < Workbench::Task
          input  :name
          output :greeting

          def run
            store_output(:greeting, "Hello, \#{fetch_input(:name)}!")
          end
        end
      RUBY

      File.write(File.join(dir, 'pipelines', 'greet.yml'),
                 YAML.dump('name' => 'greet', 'tasks' => [{ 'name' => 'greet' }]))

      File.write(File.join(dir, 'workbench.yml'),
                 YAML.dump('server' => { 'api_key' => @api_key, 'port' => SMOKE_PORT }))
    end

    # ---------------------------------------------------------------------------
    # CLI helpers
    # ---------------------------------------------------------------------------

    def workbench_cmd
      if File.exist?(WORKBENCH_BIN)
        # Running from gem source tree or installed gem with bin/ present —
        # use explicit -I so the source lib/ takes precedence.
        "bundle exec ruby -I#{WORKBENCH_LIB} #{WORKBENCH_BIN}"
      else
        'bundle exec workbench'
      end
    end

    def cli_run(subcmd, dir:)
      system(BUNDLE_ENV, "#{workbench_cmd} #{subcmd}", chdir: dir, out: File::NULL, err: File::NULL)
    end

    # ---------------------------------------------------------------------------
    # Server lifecycle
    # ---------------------------------------------------------------------------

    def with_server(dir)
      pid = spawn(BUNDLE_ENV, "#{workbench_cmd} serve --port #{SMOKE_PORT}",
                  chdir: dir, out: File::NULL, err: File::NULL)
      wait_for_server
      yield
    rescue => e
      puts "  ERROR  Server error: #{e.message}"
      @failed += 1
    ensure
      Process.kill('TERM', pid) rescue nil
      Process.wait(pid)         rescue nil
    end

    def wait_for_server
      deadline = Time.now + BOOT_TIMEOUT
      loop do
        Net::HTTP.get_response(URI("http://localhost:#{SMOKE_PORT}/"))
        return  # any response means the server is up
      rescue Errno::ECONNREFUSED, Errno::ECONNRESET
        raise "Server did not start within #{BOOT_TIMEOUT}s" if Time.now > deadline
        sleep 0.3
      end
    end

    # ---------------------------------------------------------------------------
    # HTTP helper
    # ---------------------------------------------------------------------------

    def post(path, body, auth: nil)
      uri = URI("http://localhost:#{SMOKE_PORT}#{path}")
      req = Net::HTTP::Post.new(uri, 'Content-Type' => 'application/json')
      req['Authorization'] = "Bearer #{auth}" if auth
      req.body = body.to_json
      Net::HTTP.start(uri.host, uri.port, read_timeout: 5) { |http| http.request(req) }
    end

    # ---------------------------------------------------------------------------
    # Assertion helper
    # ---------------------------------------------------------------------------

    def check(label)
      result = yield
      if result
        puts "  PASS  #{label}"
        @passed += 1
      else
        puts "  FAIL  #{label}"
        @failed += 1
      end
    rescue => e
      puts "  FAIL  #{label} (#{e.class}: #{e.message})"
      @failed += 1
    end
  end
end
