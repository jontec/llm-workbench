require_relative '../test_helper'
require 'fileutils'
require 'tmpdir'
require 'json'

class EvalResultWriterTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def make_result(eval_name: 'my_eval', dataset: 'golden_emails',
                  pass_count: 2, fail_count: 1, error_count: 0,
                  metrics: { exact_match: 0.667 }, case_results: nil)
    default_cases = [
      { case_id: 'case_01', group_name: nil, passed: true,  error: nil, metrics: { exact_match: 1.0 }, outputs: {} },
      { case_id: 'case_02', group_name: nil, passed: true,  error: nil, metrics: { exact_match: 1.0 }, outputs: {} },
      { case_id: 'case_03', group_name: nil, passed: false, error: nil, metrics: { exact_match: 0.0 }, outputs: {} },
    ]
    sr = Workbench::SubjectResult.new(
      subject_name: :my_subject,
      case_count:   3,
      pass_count:   pass_count,
      fail_count:   fail_count,
      error_count:  error_count,
      pass_rate:    pass_count.to_f / 3,
      metrics:      metrics,
      case_results: case_results || default_cases
    )
    Workbench::EvalRunResult.new(
      eval_name:       eval_name,
      run_id:          'abc123def456',
      started_at:      Time.new(2026, 4, 23, 10, 0, 0),
      finished_at:     Time.new(2026, 4, 23, 10, 1, 30),
      dataset_name:    dataset,
      subject_results: [sr]
    )
  end

  def write_result(result = nil)
    result ||= make_result
    Dir.mktmpdir do |dir|
      writer    = Workbench::EvalResultWriter.new(result, base_dir: dir)
      output    = writer.write
      yield output, dir
    end
  end

  # ---------------------------------------------------------------------------
  # Output directory
  # ---------------------------------------------------------------------------

  def test_write_returns_output_directory_path
    write_result do |output_dir|
      refute_nil output_dir
      assert File.directory?(output_dir)
    end
  end

  def test_output_dir_is_date_stamped
    write_result do |output_dir|
      assert_includes output_dir, '2026-04-23'
    end
  end

  def test_output_dir_includes_eval_name
    write_result do |output_dir|
      assert_includes output_dir, 'my_eval'
    end
  end

  def test_collision_avoidance_appends_suffix
    result = make_result
    Dir.mktmpdir do |dir|
      writer = Workbench::EvalResultWriter.new(result, base_dir: dir)
      first  = writer.write
      second = Workbench::EvalResultWriter.new(result, base_dir: dir).write
      third  = Workbench::EvalResultWriter.new(result, base_dir: dir).write

      refute_equal first,  second
      refute_equal second, third
      assert_match(/_2$/, second)
      assert_match(/_3$/, third)
    end
  end

  def test_output_dir_created_automatically
    result = make_result
    Dir.mktmpdir do |dir|
      nested_base = File.join(dir, 'deeply', 'nested', 'results')
      writer      = Workbench::EvalResultWriter.new(result, base_dir: nested_base)
      output      = writer.write
      assert File.directory?(output)
    end
  end

  # ---------------------------------------------------------------------------
  # run.json
  # ---------------------------------------------------------------------------

  def test_run_json_is_written
    write_result do |output_dir|
      assert File.exist?(File.join(output_dir, 'run.json'))
    end
  end

  def test_run_json_contains_eval_name
    write_result do |output_dir|
      data = JSON.parse(File.read(File.join(output_dir, 'run.json')))
      assert_equal 'my_eval', data['eval']
    end
  end

  def test_run_json_contains_run_id
    write_result do |output_dir|
      data = JSON.parse(File.read(File.join(output_dir, 'run.json')))
      assert_equal 'abc123def456', data['run_id']
    end
  end

  def test_run_json_contains_timestamps
    write_result do |output_dir|
      data = JSON.parse(File.read(File.join(output_dir, 'run.json')))
      assert data['started_at']
      assert data['finished_at']
    end
  end

  def test_run_json_contains_dataset_name
    write_result do |output_dir|
      data = JSON.parse(File.read(File.join(output_dir, 'run.json')))
      assert_equal 'golden_emails', data['dataset']
    end
  end

  def test_run_json_subject_contains_counts
    write_result do |output_dir|
      data    = JSON.parse(File.read(File.join(output_dir, 'run.json')))
      subject = data['subjects'].first
      assert_equal 3,   subject['case_count']
      assert_equal 2,   subject['pass_count']
      assert_equal 1,   subject['fail_count']
      assert_equal 0,   subject['error_count']
    end
  end

  def test_run_json_subject_contains_pass_rate
    write_result do |output_dir|
      data    = JSON.parse(File.read(File.join(output_dir, 'run.json')))
      subject = data['subjects'].first
      assert_in_delta 0.667, subject['pass_rate'], 0.001
    end
  end

  def test_run_json_subject_contains_metrics
    write_result do |output_dir|
      data    = JSON.parse(File.read(File.join(output_dir, 'run.json')))
      subject = data['subjects'].first
      assert_in_delta 0.667, subject['metrics']['exact_match'], 0.001
    end
  end

  def test_run_json_cases_contain_per_case_detail
    write_result do |output_dir|
      data  = JSON.parse(File.read(File.join(output_dir, 'run.json')))
      cases = data['subjects'].first['cases']
      assert_equal 3, cases.length
      assert_equal 'case_01', cases.first['case_id']
      assert_equal true,      cases.first['passed']
      assert_equal false,     cases.last['passed']
    end
  end

  def test_run_json_is_valid_json
    write_result do |output_dir|
      raw = File.read(File.join(output_dir, 'run.json'))
      assert_silent { JSON.parse(raw) }
    end
  end

  # ---------------------------------------------------------------------------
  # summary.txt
  # ---------------------------------------------------------------------------

  def test_summary_txt_is_written
    write_result do |output_dir|
      assert File.exist?(File.join(output_dir, 'summary.txt'))
    end
  end

  def test_summary_contains_eval_name
    write_result do |output_dir|
      content = File.read(File.join(output_dir, 'summary.txt'))
      assert_includes content, 'my_eval'
    end
  end

  def test_summary_contains_run_id
    write_result do |output_dir|
      content = File.read(File.join(output_dir, 'summary.txt'))
      assert_includes content, 'abc123def456'
    end
  end

  def test_summary_contains_pass_rate
    write_result do |output_dir|
      content = File.read(File.join(output_dir, 'summary.txt'))
      assert_includes content, '2/3'
    end
  end

  def test_summary_contains_failed_case_ids
    write_result do |output_dir|
      content = File.read(File.join(output_dir, 'summary.txt'))
      assert_includes content, 'FAILED'
      assert_includes content, 'case_03'
    end
  end

  def test_summary_contains_error_entries
    error_cases = [
      { case_id: 'case_01', group_name: nil, passed: nil, error: 'RuntimeError: boom', metrics: {}, outputs: {} }
    ]
    sr = Workbench::SubjectResult.new(
      subject_name: :my_subject, case_count: 1, pass_count: 0,
      fail_count: 0, error_count: 1, pass_rate: nil,
      metrics: {}, case_results: error_cases
    )
    result = Workbench::EvalRunResult.new(
      eval_name: 'my_eval', run_id: 'abc', started_at: Time.now,
      finished_at: Time.now, dataset_name: 'ds', subject_results: [sr]
    )
    Dir.mktmpdir do |dir|
      output  = Workbench::EvalResultWriter.new(result, base_dir: dir).write
      content = File.read(File.join(output, 'summary.txt'))
      assert_includes content, 'ERROR'
      assert_includes content, 'case_01'
      assert_includes content, 'RuntimeError: boom'
    end
  end

  def test_summary_ends_with_newline
    write_result do |output_dir|
      content = File.read(File.join(output_dir, 'summary.txt'))
      assert content.end_with?("\n")
    end
  end
end
