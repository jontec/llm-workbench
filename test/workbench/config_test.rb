require_relative '../test_helper'

class ConfigTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Defaults
  # ---------------------------------------------------------------------------

  def test_default_port
    assert_equal 9292, Workbench::Config.new.server_port
  end

  def test_default_host
    assert_equal '0.0.0.0', Workbench::Config.new.server_host
  end

  def test_default_base_path_is_nil
    assert_nil Workbench::Config.new.server_base_path
  end

  def test_default_api_key_is_nil
    assert_nil Workbench::Config.new.server_api_key
  end

  def test_default_openapi_is_true
    assert Workbench::Config.new.server_openapi
  end

  # ---------------------------------------------------------------------------
  # Override via data hash
  # ---------------------------------------------------------------------------

  def test_overrides_port
    config = Workbench::Config.new('server' => { 'port' => 3000 })
    assert_equal 3000, config.server_port
  end

  def test_overrides_base_path
    config = Workbench::Config.new('server' => { 'base_path' => '/api/v1' })
    assert_equal '/api/v1', config.server_base_path
  end

  def test_openapi_false_when_set
    config = Workbench::Config.new('server' => { 'openapi' => false })
    refute config.server_openapi
  end

  # ---------------------------------------------------------------------------
  # api_key env var resolution
  # ---------------------------------------------------------------------------

  def test_api_key_plain_string
    config = Workbench::Config.new('server' => { 'api_key' => 'secret' })
    assert_equal 'secret', config.server_api_key
  end

  def test_api_key_resolves_env_var
    ENV['WORKBENCH_TEST_KEY'] = 'from-env'
    config = Workbench::Config.new('server' => { 'api_key' => '$WORKBENCH_TEST_KEY' })
    assert_equal 'from-env', config.server_api_key
  ensure
    ENV.delete('WORKBENCH_TEST_KEY')
  end

  def test_api_key_returns_nil_for_missing_env_var
    ENV.delete('WORKBENCH_MISSING_KEY')
    config = Workbench::Config.new('server' => { 'api_key' => '$WORKBENCH_MISSING_KEY' })
    assert_nil config.server_api_key
  end

  # ---------------------------------------------------------------------------
  # Config.load from file
  # ---------------------------------------------------------------------------

  def test_load_from_file
    in_tmpdir do |dir|
      path = File.join(dir, 'workbench.yml')
      File.write(path, YAML.dump('server' => { 'port' => 4567, 'api_key' => 'file-key' }))
      config = Workbench::Config.load(path)
      assert_equal 4567,       config.server_port
      assert_equal 'file-key', config.server_api_key
    end
  end

  def test_load_returns_defaults_when_file_absent
    config = Workbench::Config.load('/nonexistent/workbench.yml')
    assert_equal 9292, config.server_port
  end

  private

  def in_tmpdir(&block)
    Dir.mktmpdir('workbench_config_test', &block)
  end
end
