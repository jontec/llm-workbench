require_relative '../test_helper'

class EndpointIntegrityTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # detect_issues — :empty
  # ---------------------------------------------------------------------------

  def test_detects_empty_endpoint_file
    in_tmpdir do |dir|
      write_endpoint(dir, 'empty.yml', { 'methods' => {} })
      issues = Workbench::Endpoint.detect_issues(dir)
      assert_equal 1, issues.size
      assert_equal :empty, issues.first[:type]
      assert_equal '/empty', issues.first[:route]
    end
  end

  def test_no_issue_for_valid_endpoint
    in_tmpdir do |dir|
      Workbench::Pipeline.stub(:find, stub_pipeline) do
        write_endpoint(dir, 'code-review.yml', {
          'methods' => { 'POST' => { 'pipeline' => 'code_review', 'async' => false } }
        })
        issues = Workbench::Endpoint.detect_issues(dir)
        assert_empty issues
      end
    end
  end

  # ---------------------------------------------------------------------------
  # detect_issues — :missing
  # ---------------------------------------------------------------------------

  def test_detects_missing_pipeline_reference
    in_tmpdir do |dir|
      write_endpoint(dir, 'broken.yml', {
        'methods' => { 'POST' => { 'pipeline' => 'nonexistent', 'async' => false } }
      })
      Workbench::Pipeline.stub(:find, nil) do
        Workbench::Task.stub(:find, ->(_) { raise NameError }) do
          issues = Workbench::Endpoint.detect_issues(dir)
          missing = issues.select { |i| i[:type] == :missing }
          assert_equal 1, missing.size
          assert_equal 'POST',        missing.first[:verb]
          assert_equal 'nonexistent', missing.first[:target]
          assert_equal '/broken',     missing.first[:route]
        end
      end
    end
  end

  def test_detects_missing_on_one_verb_but_not_another
    in_tmpdir do |dir|
      write_endpoint(dir, 'mixed.yml', {
        'methods' => {
          'POST' => { 'pipeline' => 'good_pipeline',  'async' => false },
          'GET'  => { 'pipeline' => 'bad_pipeline',   'async' => false }
        }
      })
      # POST resolves fine, GET does not
      Workbench::Pipeline.stub(:find, ->(name) { name == 'good_pipeline' ? stub_pipeline : nil }) do
        Workbench::Task.stub(:find, ->(_) { raise NameError }) do
          issues = Workbench::Endpoint.detect_issues(dir)
          missing = issues.select { |i| i[:type] == :missing }
          assert_equal 1, missing.size
          assert_equal 'GET',          missing.first[:verb]
          assert_equal 'bad_pipeline', missing.first[:target]
        end
      end
    end
  end

  # ---------------------------------------------------------------------------
  # detect_issues — :duplicate
  # ---------------------------------------------------------------------------

  def test_detects_duplicate_routes
    in_tmpdir do |dir|
      # Both dasherize to /code-review
      write_endpoint(dir, 'code-review.yml', { 'methods' => {} })
      write_endpoint(dir, 'code_review.yml', { 'methods' => {} })
      issues = Workbench::Endpoint.detect_issues(dir)
      duplicates = issues.select { |i| i[:type] == :duplicate }
      assert_equal 1, duplicates.size
      assert_equal '/code-review', duplicates.first[:route]
      assert_equal 2, duplicates.first[:files].size
    end
  end

  # ---------------------------------------------------------------------------
  # cleanup!
  # ---------------------------------------------------------------------------

  def test_cleanup_deletes_empty_file
    in_tmpdir do |dir|
      file = write_endpoint(dir, 'empty.yml', { 'methods' => {} })
      issues = [{ type: :empty, route: '/empty', file: file }]
      Workbench::Endpoint.cleanup!(issues, dir)
      refute File.exist?(file)
    end
  end

  def test_cleanup_removes_missing_verb_entry
    in_tmpdir do |dir|
      file = write_endpoint(dir, 'mixed.yml', {
        'methods' => {
          'POST' => { 'pipeline' => 'good', 'async' => false },
          'GET'  => { 'pipeline' => 'bad',  'async' => false }
        }
      })
      issues = [{ type: :missing, route: '/mixed', verb: 'GET', target: 'bad', file: file }]
      Workbench::Endpoint.cleanup!(issues, dir)
      yaml = YAML.load_file(file)
      refute yaml['methods'].key?('GET'),  'expected GET to be removed'
      assert yaml['methods'].key?('POST'), 'expected POST to remain'
    end
  end

  def test_cleanup_deletes_file_when_last_method_removed
    in_tmpdir do |dir|
      file = write_endpoint(dir, 'broken.yml', {
        'methods' => { 'POST' => { 'pipeline' => 'bad', 'async' => false } }
      })
      issues = [{ type: :missing, route: '/broken', verb: 'POST', target: 'bad', file: file }]
      Workbench::Endpoint.cleanup!(issues, dir)
      refute File.exist?(file)
    end
  end

  def test_cleanup_does_not_touch_duplicate_issues
    in_tmpdir do |dir|
      file_a = write_endpoint(dir, 'code-review.yml', { 'methods' => {} })
      file_b = write_endpoint(dir, 'code_review.yml', { 'methods' => {} })
      issues = [{ type: :duplicate, route: '/code-review', files: [file_a, file_b] }]
      Workbench::Endpoint.cleanup!(issues, dir)
      # Neither file should be touched
      assert File.exist?(file_a)
      assert File.exist?(file_b)
    end
  end

  private

  def in_tmpdir(&block)
    Dir.mktmpdir('workbench_integrity_test', &block)
  end

  def write_endpoint(dir, filename, content)
    path = File.join(dir, filename)
    File.write(path, YAML.dump(content))
    path
  end

  def stub_pipeline
    Object.new
  end
end
