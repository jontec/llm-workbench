require_relative '../test_helper'
require 'fileutils'
require 'tmpdir'

class EvalDatasetCliTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Helpers — build a DirectPathDataset and stub Dataset.find
  # ---------------------------------------------------------------------------

  def with_inspect(dataset, &block)
    out, _err = capture_io do
      Workbench::Dataset.stub(:find, dataset) do
        Workbench::EvalDatasetCLI.start(['inspect', dataset.name])
      end
    end
    block.call(out)
  end

  def flat_dataset(files:, **opts)
    Dir.mktmpdir do |dir|
      fixture_root = File.join(dir, 'my_dataset')
      FileUtils.mkdir_p(fixture_root)
      files.each { |name, content| File.write(File.join(fixture_root, name), content) }
      ds = DirectPathDataset.new(fixture_root,
        include_patterns: ['**/*'], ignore_patterns: [], sort: 'asc',
        **opts)
      yield ds
    end
  end

  def case_dir_dataset(cases:, case_config: {}, **opts)
    Dir.mktmpdir do |dir|
      fixture_root = File.join(dir, 'my_dataset')
      cases.each do |case_name, files|
        case_path = File.join(fixture_root, case_name)
        FileUtils.mkdir_p(case_path)
        files.each do |subpath, content|
          full = File.join(case_path, subpath)
          FileUtils.mkdir_p(File.dirname(full))
          File.write(full, content)
        end
      end
      ds = DirectPathDataset.new(fixture_root,
        include_patterns: ['**/*'], ignore_patterns: [], sort: 'asc',
        directory_mode: 'case', case_config: case_config, **opts)
      yield ds
    end
  end

  def group_dataset(groups:, group_config: {}, case_config: {})
    Dir.mktmpdir do |dir|
      fixture_root = File.join(dir, 'my_dataset')
      groups.each do |group_name, cases|
        cases.each do |case_name, files|
          case_path = File.join(fixture_root, group_name, case_name)
          FileUtils.mkdir_p(case_path)
          files.each do |filename, content|
            File.write(File.join(case_path, filename), content)
          end
        end
      end
      ds = DirectPathDataset.new(fixture_root,
        include_patterns: ['**/*'], ignore_patterns: [], sort: 'asc',
        directory_mode: 'group', group_config: group_config, case_config: case_config)
      yield ds
    end
  end

  # ---------------------------------------------------------------------------
  # Header — flat/case mode
  # ---------------------------------------------------------------------------

  def test_shows_dataset_name
    flat_dataset(files: { 'email.txt' => 'hi' }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, ds.name
      end
    end
  end

  def test_shows_path_with_fixtures_prefix
    flat_dataset(files: { 'email.txt' => 'hi' }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, "fixtures/"
      end
    end
  end

  def test_shows_default_mode_label
    flat_dataset(files: { 'email.txt' => 'hi' }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, 'default'
      end
    end
  end

  def test_shows_case_count_in_header
    flat_dataset(files: { 'a.txt' => '', 'b.txt' => '' }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, '2 cases'
      end
    end
  end

  def test_singular_case_count
    flat_dataset(files: { 'a.txt' => '' }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, '1 case'
        refute_includes out, '1 cases'
      end
    end
  end

  def test_case_mode_label_shown
    case_dir_dataset(cases: { 'case_01' => { 'email.txt' => 'hi' } }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, 'case'
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Case listing — flat mode
  # ---------------------------------------------------------------------------

  def test_lists_case_ids
    flat_dataset(files: { 'email_a.txt' => '', 'email_b.txt' => '' }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, 'email_a'
        assert_includes out, 'email_b'
      end
    end
  end

  def test_lists_files_within_cases
    case_dir_dataset(cases: { 'case_01' => { 'email.txt' => 'hi', 'meta.txt' => 'x' } }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, 'email.txt'
        assert_includes out, 'meta.txt'
      end
    end
  end

  def test_annotates_input_files
    case_dir_dataset(
      cases: { 'case_01' => { 'input/email.txt' => 'hi', 'other.txt' => 'x' } },
      case_config: { 'inputs' => ['input/**'] }
    ) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, '→ input'
      end
    end
  end

  def test_annotates_output_files
    case_dir_dataset(
      cases: { 'case_01' => { 'expected/result.json' => '{}', 'input.txt' => 'x' } },
      case_config: { 'outputs' => ['expected/**'] }
    ) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, '→ output'
      end
    end
  end

  def test_unannotated_files_show_no_tag
    case_dir_dataset(
      cases: { 'case_01' => { 'input.txt' => 'hi', 'meta.txt' => 'x' } },
      case_config: { 'inputs' => ['input.txt'] }
    ) do |ds|
      with_inspect(ds) do |out|
        lines = out.lines.map(&:chomp)
        meta_line = lines.find { |l| l.include?('meta.txt') }
        refute_nil meta_line
        refute_includes meta_line, '→'
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Group mode
  # ---------------------------------------------------------------------------

  def test_group_mode_shows_group_label
    group_dataset(groups: {
      'easy' => { 'case_01' => { 'email.txt' => 'hi' } }
    }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, 'group'
        assert_includes out, '[easy]'
      end
    end
  end

  def test_group_mode_shows_group_and_case_counts
    group_dataset(groups: {
      'easy' => { 'case_01' => { 'e.txt' => '' }, 'case_02' => { 'e.txt' => '' } },
      'hard' => { 'case_01' => { 'e.txt' => '' } }
    }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, '2 groups'
        assert_includes out, '3 cases'
      end
    end
  end

  def test_group_mode_lists_cases_under_groups
    group_dataset(groups: {
      'easy' => { 'case_01' => { 'email.txt' => 'hi' } },
      'hard' => { 'case_01' => { 'email.txt' => 'hi' } }
    }) do |ds|
      with_inspect(ds) do |out|
        assert_includes out, '[easy]'
        assert_includes out, '[hard]'
        assert_includes out, 'case_01'
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Warnings
  # ---------------------------------------------------------------------------

  def test_shows_warnings_for_stray_files
    Dir.mktmpdir do |dir|
      fixture_root = File.join(dir, 'my_dataset')
      group_dir    = File.join(fixture_root, 'easy')
      case_dir     = File.join(group_dir, 'case_01')
      FileUtils.mkdir_p(case_dir)
      File.write(File.join(case_dir,  'email.txt'), 'hi')
      File.write(File.join(group_dir, 'stray.txt'), 'ignored')

      ds = DirectPathDataset.new(fixture_root,
        include_patterns: ['**/*'], ignore_patterns: [], sort: 'asc',
        directory_mode: 'group', group_config: {}, case_config: {})

      with_inspect(ds) do |out|
        assert_includes out, 'Warnings'
        assert_includes out, 'stray.txt'
        assert_includes out, 'file directly under group directory'
      end
    end
  end

  def test_no_warnings_section_when_clean
    group_dataset(groups: {
      'easy' => { 'case_01' => { 'email.txt' => 'hi' } }
    }) do |ds|
      with_inspect(ds) do |out|
        refute_includes out, 'Warnings'
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  def test_prints_error_when_dataset_not_found
    Workbench::Dataset.stub(:find, ->(_) { raise ArgumentError, "Dataset 'missing' not found" }) do
      out, _ = capture_io do
        begin
          Workbench::EvalDatasetCLI.start(['inspect', 'missing'])
        rescue SystemExit
          # exit(1) called
        end
      end
      assert_includes out, "Error:"
      assert_includes out, "missing"
    end
  end
end
