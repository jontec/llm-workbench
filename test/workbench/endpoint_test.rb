require_relative '../test_helper'

class EndpointTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # file_to_route
  # ---------------------------------------------------------------------------

  def test_file_to_route_simple_name
    assert_equal '/code-review', Workbench::Endpoint.file_to_route('endpoints/code_review.yml')
  end

  def test_file_to_route_nested_path
    assert_equal '/tools/linter', Workbench::Endpoint.file_to_route('endpoints/tools/linter.yml')
  end

  def test_file_to_route_already_dasherized
    assert_equal '/code-review', Workbench::Endpoint.file_to_route('endpoints/code-review.yml')
  end

  def test_file_to_route_deeply_nested
    assert_equal '/api/tools/linter', Workbench::Endpoint.file_to_route('endpoints/api/tools/linter.yml')
  end

  # ---------------------------------------------------------------------------
  # route_to_file
  # ---------------------------------------------------------------------------

  def test_route_to_file_simple
    assert_equal 'endpoints/code-review.yml', Workbench::Endpoint.route_to_file('/code-review')
  end

  def test_route_to_file_nested
    assert_equal 'endpoints/tools/linter.yml', Workbench::Endpoint.route_to_file('/tools/linter')
  end

  def test_route_to_file_custom_directory
    assert_equal 'custom/tools/linter.yml', Workbench::Endpoint.route_to_file('/tools/linter', 'custom')
  end

  # ---------------------------------------------------------------------------
  # register!
  # ---------------------------------------------------------------------------

  def test_register_writes_endpoint_file
    in_tmpdir do |dir|
      Workbench::Endpoint.register!('code_review', { type: 'pipeline' }, dir)
      file = File.join(dir, 'code-review.yml')
      assert File.exist?(file), "expected endpoint file to be created at #{file}"
    end
  end

  def test_register_file_contains_correct_structure
    in_tmpdir do |dir|
      Workbench::Endpoint.register!('code_review', { type: 'pipeline', method: 'POST', async: false }, dir)
      yaml = YAML.load_file(File.join(dir, 'code-review.yml'))
      entry = yaml['methods']['POST']
      assert_equal 'code_review', entry['pipeline']
      assert_equal false,         entry['async']
      assert entry['deployed_at'], 'expected deployed_at to be set'
    end
  end

  def test_register_custom_path
    in_tmpdir do |dir|
      Workbench::Endpoint.register!('run_linter', { type: 'task', path: '/tools/linter' }, dir)
      assert File.exist?(File.join(dir, 'tools', 'linter.yml'))
    end
  end

  def test_register_merges_second_method_into_existing_file
    in_tmpdir do |dir|
      Workbench::Endpoint.register!('run_linter',    { type: 'pipeline', method: 'POST', path: '/linter' }, dir)
      Workbench::Endpoint.register!('linter_status', { type: 'pipeline', method: 'GET',  path: '/linter' }, dir)

      yaml = YAML.load_file(File.join(dir, 'linter.yml'))
      assert yaml['methods'].key?('POST'), 'expected POST method to be present'
      assert yaml['methods'].key?('GET'),  'expected GET method to be present'
    end
  end

  def test_register_raises_without_type
    in_tmpdir do |dir|
      assert_raises(KeyError) do
        Workbench::Endpoint.register!('code_review', {}, dir)
      end
    end
  end

  # ---------------------------------------------------------------------------
  # unregister!
  # ---------------------------------------------------------------------------

  def test_unregister_removes_specific_method
    in_tmpdir do |dir|
      Workbench::Endpoint.register!('code_review', { type: 'pipeline', method: 'POST' }, dir)
      Workbench::Endpoint.register!('code_review', { type: 'pipeline', method: 'GET' }, dir)
      Workbench::Endpoint.unregister!('code_review', { method: 'GET' }, dir)

      yaml = YAML.load_file(File.join(dir, 'code-review.yml'))
      refute yaml['methods'].key?('GET'),  'expected GET to be removed'
      assert yaml['methods'].key?('POST'), 'expected POST to remain'
    end
  end

  def test_unregister_deletes_file_when_last_method_removed
    in_tmpdir do |dir|
      Workbench::Endpoint.register!('code_review', { type: 'pipeline', method: 'POST' }, dir)
      Workbench::Endpoint.unregister!('code_review', {}, dir)
      refute File.exist?(File.join(dir, 'code-review.yml')), 'expected file to be deleted'
    end
  end

  def test_unregister_removes_empty_parent_directories
    in_tmpdir do |dir|
      Workbench::Endpoint.register!('run_linter', { type: 'task', path: '/tools/linter' }, dir)
      Workbench::Endpoint.unregister!('run_linter', { path: '/tools/linter' }, dir)
      refute Dir.exist?(File.join(dir, 'tools')), 'expected empty tools/ directory to be removed'
    end
  end

  def test_unregister_is_a_noop_when_file_does_not_exist
    in_tmpdir do |dir|
      # should not raise
      Workbench::Endpoint.unregister!('nonexistent', {}, dir)
    end
  end

  # ---------------------------------------------------------------------------
  # all
  # ---------------------------------------------------------------------------

  def test_all_returns_endpoints_from_directory
    in_tmpdir do |dir|
      Workbench::Endpoint.register!('code_review', { type: 'pipeline' }, dir)
      Workbench::Endpoint.register!('run_linter', { type: 'task', path: '/tools/linter' }, dir)
      endpoints = Workbench::Endpoint.all(dir)
      routes = endpoints.map(&:route)
      assert_includes routes, '/code-review'
      assert_includes routes, '/tools/linter'
    end
  end

  def test_all_returns_empty_array_when_directory_is_absent
    assert_equal [], Workbench::Endpoint.all('nonexistent_dir_xyz')
  end

  private

  def in_tmpdir(&block)
    Dir.mktmpdir('workbench_endpoint_test', &block)
  end
end
