require_relative '../test_helper'
require 'fileutils'
require 'tmpdir'

class DatasetTest < Minitest::Test

  # Temporarily override the FixturesDir and DatasetDir constants for each test
  # by pointing Dataset.new directly at a YAML path and using an absolute base.

  # ---------------------------------------------------------------------------
  # YAML loading
  # ---------------------------------------------------------------------------

  def test_loads_name_from_yaml
    with_dataset_yaml('name: golden_emails') do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_equal 'golden_emails', ds.name
    end
  end

  def test_name_falls_back_to_filename
    with_dataset_yaml('{}') do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_equal File.basename(yaml_path, '.*'), ds.name
    end
  end

  def test_path_defaults_to_name
    with_dataset_yaml("name: golden_emails\n") do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_equal 'golden_emails', ds.path
    end
  end

  def test_path_can_be_overridden
    with_dataset_yaml("name: invoices\npath: invoices/smoke\n") do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_equal 'invoices/smoke', ds.path
    end
  end

  def test_include_defaults_to_glob_all
    with_dataset_yaml('name: x') do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_equal ['**/*'], ds.include_patterns
    end
  end

  def test_include_can_be_set
    with_dataset_yaml("name: x\ninclude:\n  - '*.txt'\n") do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_equal ['*.txt'], ds.include_patterns
    end
  end

  def test_ignore_defaults_to_empty
    with_dataset_yaml('name: x') do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_equal [], ds.ignore_patterns
    end
  end

  def test_sort_defaults_to_asc
    with_dataset_yaml('name: x') do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_equal 'asc', ds.sort
    end
  end

  # ---------------------------------------------------------------------------
  # Case discovery — files as cases
  # ---------------------------------------------------------------------------

  def test_flat_files_become_cases
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'email_a.txt', 'hello')
      write_file(fixtures_root, 'email_b.txt', 'world')

      ds = dataset_for(fixtures_root)
      cases = ds.cases

      assert_equal 2, cases.length
      assert_equal 'email_a', cases[0].id
      assert_equal 'email_b', cases[1].id
    end
  end

  def test_file_case_exposes_file_via_files_array
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'email.txt', 'content')

      ds    = dataset_for(fixtures_root)
      kase  = ds.cases.first
      file  = kase.files.first

      assert_equal 'email.txt', file.name
      assert_equal 'content',   file.read
    end
  end

  def test_file_case_sets_root_path_to_fixture_dir
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'email.txt', '')

      ds   = dataset_for(fixtures_root)
      kase = ds.cases.first

      assert_equal fixtures_root, kase.root_path
    end
  end

  # ---------------------------------------------------------------------------
  # Case discovery — directories as cases
  # ---------------------------------------------------------------------------

  def test_directories_become_cases_when_present
    with_fixture_dir do |fixtures_root|
      FileUtils.mkdir_p(File.join(fixtures_root, 'case_01'))
      write_file(File.join(fixtures_root, 'case_01'), 'email.txt', 'hi')
      FileUtils.mkdir_p(File.join(fixtures_root, 'case_02'))
      write_file(File.join(fixtures_root, 'case_02'), 'email.txt', 'bye')

      ds    = dataset_for(fixtures_root)
      cases = ds.cases

      assert_equal 2,        cases.length
      assert_equal 'case_01', cases[0].id
      assert_equal 'case_02', cases[1].id
    end
  end

  def test_directory_case_root_path_is_the_directory
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir, 'email.txt', '')

      ds   = dataset_for(fixtures_root)
      kase = ds.cases.first

      assert_equal case_dir, kase.root_path
    end
  end

  def test_directory_case_collects_nested_files
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      sub_dir  = File.join(case_dir, 'sub')
      FileUtils.mkdir_p(sub_dir)
      write_file(case_dir, 'top.txt', 'a')
      write_file(sub_dir,  'nested.txt', 'b')

      ds    = dataset_for(fixtures_root)
      files = ds.cases.first.files

      names = files.map(&:name).sort
      assert_equal ['nested.txt', 'top.txt'], names
    end
  end

  def test_directory_case_relative_path_is_relative_to_case_root
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      sub_dir  = File.join(case_dir, 'sub')
      FileUtils.mkdir_p(sub_dir)
      write_file(sub_dir, 'nested.txt', '')

      ds   = dataset_for(fixtures_root)
      file = ds.cases.first.files.first

      assert_equal 'sub/nested.txt', file.relative_path
    end
  end

  def test_directories_take_precedence_over_sibling_files
    with_fixture_dir do |fixtures_root|
      dir = File.join(fixtures_root, 'case_01')
      FileUtils.mkdir_p(dir)
      write_file(dir,          'email.txt', '')
      write_file(fixtures_root, 'stray.txt', '')  # sibling file — should be ignored

      ds    = dataset_for(fixtures_root)
      cases = ds.cases

      assert_equal 1, cases.length
      assert_equal 'case_01', cases.first.id
    end
  end

  # ---------------------------------------------------------------------------
  # Filtering
  # ---------------------------------------------------------------------------

  def test_hidden_files_excluded_from_cases
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, '.hidden', 'secret')
      write_file(fixtures_root, 'visible.txt', 'hello')

      ds    = dataset_for(fixtures_root)
      cases = ds.cases

      assert_equal 1, cases.length
      assert_equal 'visible', cases.first.id
    end
  end

  def test_ds_store_excluded
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir, '.DS_Store', '')
      write_file(case_dir, 'email.txt', 'hi')

      ds    = dataset_for(fixtures_root)
      files = ds.cases.first.files

      assert_equal 1, files.length
      assert_equal 'email.txt', files.first.name
    end
  end

  def test_empty_directories_skipped
    with_fixture_dir do |fixtures_root|
      FileUtils.mkdir_p(File.join(fixtures_root, 'empty_case'))
      full_case = File.join(fixtures_root, 'full_case')
      FileUtils.mkdir_p(full_case)
      write_file(full_case, 'email.txt', 'hi')

      ds    = dataset_for(fixtures_root)
      cases = ds.cases

      assert_equal 1, cases.length
      assert_equal 'full_case', cases.first.id
    end
  end

  def test_ignore_pattern_excludes_files
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'email.txt', 'hi')
      write_file(fixtures_root, 'script.rb', 'puts')

      ds = dataset_for(fixtures_root, ignore: ['*.rb'])
      cases = ds.cases

      assert_equal 1, cases.length
      assert_equal 'email', cases.first.id
    end
  end

  def test_ignore_pattern_excludes_files_within_dir_cases
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir, 'email.txt', 'hi')
      write_file(case_dir, 'script.rb', 'puts')

      ds    = dataset_for(fixtures_root, ignore: ['**/*.rb'])
      files = ds.cases.first.files

      assert_equal 1, files.length
      assert_equal 'email.txt', files.first.name
    end
  end

  def test_include_pattern_limits_file_cases
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'email.txt', 'hi')
      write_file(fixtures_root, 'data.json', '{}')

      ds    = dataset_for(fixtures_root, include: ['*.txt'])
      cases = ds.cases

      assert_equal 1, cases.length
      assert_equal 'email', cases.first.id
    end
  end

  # ---------------------------------------------------------------------------
  # Sort order
  # ---------------------------------------------------------------------------

  def test_cases_sorted_ascending_by_default
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'c.txt', '')
      write_file(fixtures_root, 'a.txt', '')
      write_file(fixtures_root, 'b.txt', '')

      ds  = dataset_for(fixtures_root)
      ids = ds.cases.map(&:id)
      assert_equal ['a', 'b', 'c'], ids
    end
  end

  def test_cases_sorted_descending_when_specified
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'c.txt', '')
      write_file(fixtures_root, 'a.txt', '')
      write_file(fixtures_root, 'b.txt', '')

      ds  = dataset_for(fixtures_root, sort: 'desc')
      ids = ds.cases.map(&:id)
      assert_equal ['c', 'b', 'a'], ids
    end
  end

  # ---------------------------------------------------------------------------
  # Validation
  # ---------------------------------------------------------------------------

  def test_raises_when_fixture_path_does_not_exist
    with_dataset_yaml("name: missing\npath: nonexistent\n") do |yaml_path|
      ds = Workbench::Dataset.new(yaml_path)
      assert_raises(ArgumentError) { ds.cases }
    end
  end

  def test_raises_when_zero_cases_discovered
    with_fixture_dir do |fixtures_root|
      # empty directory — nothing to discover
      ds = dataset_for(fixtures_root)
      assert_raises(ArgumentError) { ds.cases }
    end
  end

  # ---------------------------------------------------------------------------
  # EvalFile API
  # ---------------------------------------------------------------------------

  def test_eval_file_name
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'email.txt', 'hello')
      file = dataset_for(fixtures_root).cases.first.files.first
      assert_equal 'email.txt', file.name
    end
  end

  def test_eval_file_read
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'email.txt', 'hello world')
      file = dataset_for(fixtures_root).cases.first.files.first
      assert_equal 'hello world', file.read
    end
  end

  def test_eval_file_path_is_absolute
    with_fixture_dir do |fixtures_root|
      write_file(fixtures_root, 'email.txt', '')
      file = dataset_for(fixtures_root).cases.first.files.first
      assert File.absolute_path?(file.path)
    end
  end

  private

  def with_dataset_yaml(content)
    Dir.mktmpdir do |dir|
      yaml_path = File.join(dir, 'my_dataset.yml')
      File.write(yaml_path, content)
      yield yaml_path
    end
  end

  # Creates a fixture directory and a matching Dataset that points at it.
  # Accepts optional YAML overrides for include/ignore/sort.
  def with_fixture_dir
    Dir.mktmpdir do |dir|
      fixture_root = File.join(dir, 'fixtures', 'my_dataset')
      FileUtils.mkdir_p(fixture_root)
      yield fixture_root
    end
  end

  def dataset_for(fixture_root, include: nil, ignore: nil, sort: nil)
    dataset_for_path(fixture_root, include: include, ignore: ignore, sort: sort)
  end

  def dataset_for_path(fixture_root, include: nil, ignore: nil, sort: nil)
    DirectPathDataset.new(fixture_root,
      include_patterns: include || ['**/*'],
      ignore_patterns:  ignore  || [],
      sort:             sort    || 'asc'
    )
  end

  def write_file(dir, name, content)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, name), content)
  end
end

# Test-only subclass that takes an absolute fixture path directly,
# bypassing the FixturesDir constant so tests don't depend on the filesystem layout.
class DirectPathDataset < Workbench::Dataset
  def initialize(fixture_path, include_patterns:, ignore_patterns:, sort:)
    @fixture_path     = fixture_path
    @name             = File.basename(fixture_path)
    @path             = fixture_path
    @include_patterns = include_patterns
    @ignore_patterns  = ignore_patterns
    @sort             = sort
  end

  def cases
    raise ArgumentError, "Dataset fixture path '#{@fixture_path}' does not exist" unless File.exist?(@fixture_path)
    result = discover(@fixture_path)
    raise ArgumentError, "Dataset '#{@name}' discovered zero cases" if result.empty?
    result
  end
end
