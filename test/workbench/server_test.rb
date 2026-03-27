require_relative '../test_helper'
require 'rack/test'

class ServerTest < Minitest::Test
  include Rack::Test::Methods

  # ---------------------------------------------------------------------------
  # Rack::Test requires an `app` method. Rack::Test calls `app` at request
  # time, so initialization must live in `setup`, not inside `app` itself —
  # otherwise each request would reset the class-level config.
  # ---------------------------------------------------------------------------

  def setup
    Workbench::Server.workbench_config    = test_config
    Workbench::Server.workbench_endpoints = test_endpoints
  end

  def app
    Workbench::Server
  end

  # ---------------------------------------------------------------------------
  # Authentication
  # ---------------------------------------------------------------------------

  def test_returns_401_without_authorization_header
    post_json('/greet', { name: 'world' })
    assert_equal 401, last_response.status
  end

  def test_returns_401_with_wrong_api_key
    post_json('/greet', { name: 'world' }, auth_header('wrong-key'))
    assert_equal 401, last_response.status
  end

  def test_returns_401_response_body_is_json
    post_json('/greet', { name: 'world' })
    body = JSON.parse(last_response.body)
    assert_equal 'error',        body['status']
    assert_equal 'Unauthorized', body['error']
  end

  # ---------------------------------------------------------------------------
  # Routing
  # ---------------------------------------------------------------------------

  def test_returns_404_for_unknown_route
    post_json('/nonexistent', {}, auth_header)
    assert_equal 404, last_response.status
  end

  def test_returns_405_for_wrong_verb
    get '/greet', {}, auth_header.merge('CONTENT_TYPE' => 'application/json')
    assert_equal 405, last_response.status
  end

  # ---------------------------------------------------------------------------
  # Successful dispatch
  # ---------------------------------------------------------------------------

  def test_successful_request_returns_200
    with_stub_pipeline({ greeting: 'Hello, world!' }) do
      post_json('/greet', { name: 'world' }, auth_header)
      assert_equal 200, last_response.status
    end
  end

  def test_successful_response_includes_outputs
    with_stub_pipeline({ greeting: 'Hello, world!' }) do
      post_json('/greet', { name: 'world' }, auth_header)
      body = JSON.parse(last_response.body)
      assert_equal 'ok',    body['status']
      assert_equal 'greet', body['pipeline']
      refute_nil body['outputs']
    end
  end

  def test_inputs_merged_into_pipeline_context
    received_context = {}
    with_stub_pipeline({}, received_context) do
      post_json('/greet', { name: 'Alice' }, auth_header)
    end
    assert_equal 'Alice', received_context[:name]
  end

  # ---------------------------------------------------------------------------
  # Input validation
  # ---------------------------------------------------------------------------

  def test_returns_422_for_missing_required_input
    task_list = build_stub_task_list({ name: {} })
    with_stub_pipeline({}, {}, task_list: task_list) do
      post_json('/greet', {}, auth_header)
      assert_equal 422, last_response.status
    end
  end

  def test_422_response_names_missing_field
    task_list = build_stub_task_list({ name: {} })
    with_stub_pipeline({}, {}, task_list: task_list) do
      post_json('/greet', {}, auth_header)
      body = JSON.parse(last_response.body)
      assert_equal 'Missing required inputs', body['error']
      assert_includes body['missing'], 'name'
    end
  end

  def test_optional_input_absent_still_returns_200
    task_list = build_stub_task_list({ name: { optional: true } })
    with_stub_pipeline({ greeting: 'hi' }, {}, task_list: task_list) do
      post_json('/greet', {}, auth_header)
      assert_equal 200, last_response.status
    end
  end

  # ---------------------------------------------------------------------------
  # Bad input
  # ---------------------------------------------------------------------------

  def test_returns_400_for_malformed_json
    post '/greet', 'not valid json', auth_header.merge('CONTENT_TYPE' => 'application/json')
    assert_equal 400, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal 'Invalid JSON body', body['error']
  end

  # ---------------------------------------------------------------------------
  # base_path routing
  # ---------------------------------------------------------------------------

  def test_routes_correctly_with_base_path
    Workbench::Server.workbench_config = test_config(base_path: '/api/v1')
    with_stub_pipeline({}) do
      post_json('/api/v1/greet', { name: 'world' }, auth_header)
      assert_equal 200, last_response.status
    end
  end

  def test_returns_404_without_base_path_prefix
    Workbench::Server.workbench_config = test_config(base_path: '/api/v1')
    with_stub_pipeline({}) do
      post_json('/greet', { name: 'world' }, auth_header)
      assert_equal 404, last_response.status
    end
  end

  private

  def test_config(base_path: nil)
    Workbench::Config.new('server' => {
      'api_key'   => 'test-key',
      'port'      => 9292,
      'host'      => '0.0.0.0',
      'base_path' => base_path
    })
  end

  def test_endpoints
    [Workbench::Endpoint.new('/greet', { 'POST' => { 'pipeline' => 'greet', 'async' => false } })]
  end

  def auth_header(key = 'test-key')
    { 'HTTP_AUTHORIZATION' => "Bearer #{key}" }
  end

  def post_json(path, body, headers = {})
    post path, body.to_json, headers.merge('CONTENT_TYPE' => 'application/json')
  end

  # Stubs Pipeline.find and Pipeline.lambda to return a minimal pipeline double.
  # The double captures context merges (to allow input assertions) and runs a
  # no-op. Real pipeline execution is covered by the end-to-end smoke test.
  # Note: Task#initialize calls load_prompt which hits the filesystem, making
  # real task instantiation unsuitable for these HTTP-layer unit tests.
  def with_stub_pipeline(outputs = {}, captured_context = {}, task_list: [])
    pipeline = build_stub_pipeline(outputs, captured_context, task_list: task_list)
    Workbench::Pipeline.stub(:find,   pipeline) do
      Workbench::Pipeline.stub(:lambda, pipeline) do
        yield
      end
    end
  end

  # Builds a minimal task-list stub: an array of objects whose .class responds
  # to input_definitions and output_definitions. Real Task instantiation is
  # unsuitable here because Task#initialize hits the filesystem (load_prompt).
  def build_stub_task_list(input_defs, output_defs = {})
    task_class = Class.new do
      define_singleton_method(:input_definitions)  { input_defs }
      define_singleton_method(:output_definitions) { output_defs }
    end
    stub_task = Object.new
    stub_task.define_singleton_method(:class) { task_class }
    [stub_task]
  end

  def build_stub_pipeline(outputs, captured_context, task_list: [])
    # Use captured_context as the live context hash so that merge! calls
    # made by the server are reflected back to the caller for inspection.
    captured_context.merge!(outputs)
    pipeline = Object.new
    pipeline.define_singleton_method(:context) { captured_context }
    pipeline.define_singleton_method(:run) {}
    pipeline.define_singleton_method(:task_list) { task_list }
    pipeline
  end
end
