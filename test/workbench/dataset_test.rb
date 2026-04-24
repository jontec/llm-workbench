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

  # ---------------------------------------------------------------------------
  # directory: case mode
  # ---------------------------------------------------------------------------

  def test_case_mode_uses_dirs_as_cases
    with_fixture_dir do |fixtures_root|
      FileUtils.mkdir_p(File.join(fixtures_root, 'case_01'))
      write_file(File.join(fixtures_root, 'case_01'), 'email.txt', 'hi')
      FileUtils.mkdir_p(File.join(fixtures_root, 'case_02'))
      write_file(File.join(fixtures_root, 'case_02'), 'email.txt', 'bye')

      ds = dataset_for(fixtures_root, directory: 'case')
      assert_equal ['case_01', 'case_02'], ds.cases.map(&:id)
    end
  end

  def test_case_mode_ignores_sibling_files
    with_fixture_dir do |fixtures_root|
      FileUtils.mkdir_p(File.join(fixtures_root, 'case_01'))
      write_file(File.join(fixtures_root, 'case_01'), 'email.txt', 'hi')
      write_file(fixtures_root, 'stray.txt', 'ignored')

      ds = dataset_for(fixtures_root, directory: 'case')
      assert_equal 1, ds.cases.length
      assert_equal 'case_01', ds.cases.first.id
    end
  end

  def test_case_mode_skips_empty_dirs
    with_fixture_dir do |fixtures_root|
      FileUtils.mkdir_p(File.join(fixtures_root, 'empty'))
      FileUtils.mkdir_p(File.join(fixtures_root, 'full'))
      write_file(File.join(fixtures_root, 'full'), 'email.txt', 'hi')

      ds = dataset_for(fixtures_root, directory: 'case')
      assert_equal ['full'], ds.cases.map(&:id)
    end
  end

  def test_case_mode_collects_nested_files_as_payload
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      sub_dir  = File.join(case_dir, 'input')
      FileUtils.mkdir_p(sub_dir)
      write_file(case_dir, 'top.txt', 'a')
      write_file(sub_dir,  'nested.txt', 'b')

      ds    = dataset_for(fixtures_root, directory: 'case')
      files = ds.cases.first.files
      assert_equal ['nested.txt', 'top.txt'], files.map(&:name).sort
    end
  end

  # ---------------------------------------------------------------------------
  # directory: group mode
  # ---------------------------------------------------------------------------

  def test_group_mode_treats_top_dirs_as_groups
    with_fixture_dir do |fixtures_root|
      ['easy', 'hard'].each do |group|
        dir = File.join(fixtures_root, group, 'case_01')
        FileUtils.mkdir_p(dir)
        write_file(dir, 'email.txt', 'hi')
      end

      ds     = dataset_for(fixtures_root, directory: 'group')
      groups = ds.cases.map(&:group_name).uniq.sort
      assert_equal ['easy', 'hard'], groups
    end
  end

  def test_group_mode_applies_default_discovery_within_group
    with_fixture_dir do |fixtures_root|
      group_dir = File.join(fixtures_root, 'easy')
      ['case_01', 'case_02'].each do |c|
        dir = File.join(group_dir, c)
        FileUtils.mkdir_p(dir)
        write_file(dir, 'email.txt', 'hi')
      end

      ds    = dataset_for(fixtures_root, directory: 'group')
      cases = ds.cases
      assert_equal 2, cases.length
      assert_equal ['case_01', 'case_02'], cases.map(&:id).sort
    end
  end

  def test_group_mode_sets_group_name_on_cases
    with_fixture_dir do |fixtures_root|
      dir = File.join(fixtures_root, 'easy', 'case_01')
      FileUtils.mkdir_p(dir)
      write_file(dir, 'email.txt', 'hi')

      ds = dataset_for(fixtures_root, directory: 'group')
      assert_equal 'easy', ds.cases.first.group_name
    end
  end

  def test_group_mode_files_at_group_level_are_excluded
    with_fixture_dir do |fixtures_root|
      group_dir = File.join(fixtures_root, 'easy')
      case_dir  = File.join(group_dir, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir,  'email.txt', 'hi')
      write_file(group_dir, 'stray.txt', 'ignored')

      ds    = dataset_for(fixtures_root, directory: 'group')
      files = ds.cases.first.files
      assert_equal 1, files.length
      assert_equal 'email.txt', files.first.name
    end
  end

  def test_group_mode_stray_files_recorded_as_warnings
    with_fixture_dir do |fixtures_root|
      group_dir = File.join(fixtures_root, 'easy')
      case_dir  = File.join(group_dir, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir,  'email.txt', 'hi')
      write_file(group_dir, 'stray.txt', 'ignored')

      ds = dataset_for(fixtures_root, directory: 'group')
      ds.cases
      assert_equal 1, ds.warnings.length
      assert_equal :stray_file,  ds.warnings.first[:type]
      assert_equal 'easy',       ds.warnings.first[:group]
    end
  end

  def test_group_ignore_filters_within_group
    with_fixture_dir do |fixtures_root|
      group_dir = File.join(fixtures_root, 'easy')
      ['case_01', 'case_02'].each do |c|
        dir = File.join(group_dir, c)
        FileUtils.mkdir_p(dir)
        write_file(dir, 'email.txt', 'hi')
      end

      ds    = dataset_for(fixtures_root, directory: 'group',
                          group_config: { 'ignore' => ['case_02'] })
      cases = ds.cases
      assert_equal ['case_01'], cases.map(&:id)
    end
  end

  # ---------------------------------------------------------------------------
  # case.inputs / case.outputs hints
  # ---------------------------------------------------------------------------

  def test_case_inputs_hint_classifies_files
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      input_dir = File.join(case_dir, 'input')
      FileUtils.mkdir_p(input_dir)
      write_file(input_dir, 'email.txt', 'hi')
      write_file(case_dir,  'other.txt', 'bye')

      ds   = dataset_for(fixtures_root, directory: 'case',
                         case_config: { 'inputs' => ['input/**'] })
      kase = ds.cases.first
      assert_equal 1, kase.inputs.length
      assert_equal 'email.txt', kase.inputs.first.name
    end
  end

  def test_case_outputs_hint_classifies_files
    with_fixture_dir do |fixtures_root|
      case_dir    = File.join(fixtures_root, 'case_01')
      output_dir  = File.join(case_dir, 'expected')
      FileUtils.mkdir_p(output_dir)
      write_file(output_dir, 'result.json', '{}')
      write_file(case_dir,   'input.txt',   'hi')

      ds   = dataset_for(fixtures_root, directory: 'case',
                         case_config: { 'outputs' => ['expected/**'] })
      kase = ds.cases.first
      assert_equal 1, kase.outputs.length
      assert_equal 'result.json', kase.outputs.first.name
    end
  end

  def test_unmatched_files_remain_in_files
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir, 'input.txt',  'hi')
      write_file(case_dir, 'output.txt', 'bye')
      write_file(case_dir, 'meta.txt',   'extra')

      ds   = dataset_for(fixtures_root, directory: 'case',
                         case_config: { 'inputs' => ['input.txt'], 'outputs' => ['output.txt'] })
      kase = ds.cases.first
      assert_equal 3, kase.files.length
      assert_equal 1, kase.inputs.length
      assert_equal 1, kase.outputs.length
    end
  end

  def test_no_hints_leaves_inputs_outputs_empty
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir, 'email.txt', 'hi')

      ds   = dataset_for(fixtures_root, directory: 'case')
      kase = ds.cases.first
      assert_equal [], kase.inputs
      assert_equal [], kase.outputs
    end
  end

  # ---------------------------------------------------------------------------
  # case.include / case.ignore
  # ---------------------------------------------------------------------------

  def test_case_ignore_filters_files_within_case
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir, 'email.txt',  'hi')
      write_file(case_dir, 'script.rb',  'puts')

      ds    = dataset_for(fixtures_root, directory: 'case',
                          case_config: { 'ignore' => ['*.rb'] })
      files = ds.cases.first.files
      assert_equal 1, files.length
      assert_equal 'email.txt', files.first.name
    end
  end

  def test_case_include_limits_files_within_case
    with_fixture_dir do |fixtures_root|
      case_dir = File.join(fixtures_root, 'case_01')
      FileUtils.mkdir_p(case_dir)
      write_file(case_dir, 'email.txt', 'hi')
      write_file(case_dir, 'data.json', '{}')

      ds    = dataset_for(fixtures_root, directory: 'case',
                          case_config: { 'include' => ['*.txt'] })
      files = ds.cases.first.files
      assert_equal 1, files.length
      assert_equal 'email.txt', files.first.name
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

  def dataset_for(fixture_root, include: nil, ignore: nil, sort: nil,
                  directory: nil, case_config: {}, group_config: {})
    DirectPathDataset.new(fixture_root,
      include_patterns: include || ['**/*'],
      ignore_patterns:  ignore  || [],
      sort:             sort    || 'asc',
      directory_mode:   directory,
      case_config:      case_config,
      group_config:     group_config
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
  def initialize(fixture_path, include_patterns:, ignore_patterns:, sort:,
                 directory_mode: nil, case_config: {}, group_config: {})
    @fixture_path     = fixture_path
    @name             = File.basename(fixture_path)
    @path             = fixture_path
    @include_patterns = include_patterns
    @ignore_patterns  = ignore_patterns
    @sort             = sort
    @directory_mode   = directory_mode
    @case_config      = case_config
    @group_config     = group_config
    @warnings         = []
  end

  def cases
    raise ArgumentError, "Dataset fixture path '#{@fixture_path}' does not exist" unless File.exist?(@fixture_path)
    @warnings = []
    result = case @directory_mode
             when 'case'  then discover_case_mode(@fixture_path)
             when 'group' then discover_group_mode(@fixture_path)
             else              discover_default(@fixture_path)
             end
    result = result.map { |c| apply_hints(c) }
    raise ArgumentError, "Dataset '#{@name}' discovered zero cases" if result.empty?
    result
  end
end
