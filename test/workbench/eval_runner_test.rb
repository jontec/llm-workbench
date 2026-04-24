require_relative '../test_helper'
require 'fileutils'
require 'tmpdir'

class EvalRunnerTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Helpers — build minimal eval classes and datasets without hitting disk
  # ---------------------------------------------------------------------------

  # Returns an eval class with stubbed dataset discovery.
  # The block receives (eval_instance) for each case and should call
  # record_case_result.
  def make_eval_class(subjects: [:test_subject], run_block: nil, &default_block)
    block = run_block || default_block
    klass = Class.new(Workbench::Eval) do
      subjects.each { |s| evaluates s }
      dataset :test_dataset
    end
    klass.define_method(:run, &block) if block
    stub_dataset_on(klass)
    klass
  end

  # Stubs Dataset.find so the runner doesn't touch the filesystem.
  def stub_dataset_on(klass, cases: nil)
    default_cases = cases || [
      Workbench::EvalCase.new(id: 'case_01', root_path: '/tmp', files: []),
      Workbench::EvalCase.new(id: 'case_02', root_path: '/tmp', files: []),
    ]
    dataset_stub = Minitest::Mock.new
    dataset_stub.expect(:cases, default_cases)
    Workbench::Dataset.stub(:find, dataset_stub) do
      yield if block_given?
    end
    dataset_stub
  end

  def run_eval(klass, continue_on_error: false)
    dataset_stub = Minitest::Mock.new
    default_cases = [
      Workbench::EvalCase.new(id: 'case_01', root_path: '/tmp', files: []),
      Workbench::EvalCase.new(id: 'case_02', root_path: '/tmp', files: []),
    ]
    dataset_stub.expect(:cases, default_cases)
    Workbench::Dataset.stub(:find, dataset_stub) do
      Workbench::EvalRunner.new(klass, continue_on_error: continue_on_error).run
    end
  end

  # ---------------------------------------------------------------------------
  # Basic lifecycle
  # ---------------------------------------------------------------------------

  def test_run_returns_eval_run_result
    klass = make_eval_class { record_case_result }
    result = run_eval(klass)
    assert_instance_of Workbench::EvalRunResult, result
  end

  def test_result_contains_eval_name
    klass = make_eval_class { record_case_result }
    klass.define_singleton_method(:eval_name) { :my_test_eval }
    result = run_eval(klass)
    assert_equal 'my_test_eval', result.eval_name
  end

  def test_result_contains_run_id
    klass = make_eval_class { record_case_result }
    result = run_eval(klass)
    refute_nil result.run_id
    assert_match(/\A[0-9a-f]{12}\z/, result.run_id)
  end

  def test_result_timestamps_are_set
    klass = make_eval_class { record_case_result }
    result = run_eval(klass)
    assert_instance_of Time, result.started_at
    assert_instance_of Time, result.finished_at
    assert result.finished_at >= result.started_at
  end

  def test_run_calls_setup_before_cases
    order = []
    klass = make_eval_class { order << "run_#{current_case.id}" }
    klass.define_method(:setup) { order << "setup" }
    run_eval(klass)
    assert_equal "setup", order.first
  end

  def test_run_calls_teardown_after_cases
    order = []
    klass = make_eval_class { order << "run" }
    klass.define_method(:teardown) { order << "teardown" }
    run_eval(klass)
    assert_equal "teardown", order.last
  end

  def test_run_iterates_all_cases
    case_ids = []
    klass = make_eval_class { case_ids << current_case.id; record_case_result }
    run_eval(klass)
    assert_equal ['case_01', 'case_02'], case_ids
  end

  def test_run_iterates_cases_for_each_subject
    calls = []
    klass = make_eval_class(subjects: [:subject_a, :subject_b]) do
      calls << [current_subject, current_case.id]
      record_case_result
    end
    run_eval(klass)
    assert_equal [
      [:subject_a, 'case_01'],
      [:subject_a, 'case_02'],
      [:subject_b, 'case_01'],
      [:subject_b, 'case_02'],
    ], calls
  end

  # ---------------------------------------------------------------------------
  # Pass rate aggregation
  # ---------------------------------------------------------------------------

  def test_pass_rate_computed_from_passed_booleans
    klass = make_eval_class do
      record_case_result(passed: current_case.id == 'case_01')
    end
    result = run_eval(klass)
    sr = result.subject_results.first
    assert_equal 1,   sr.pass_count
    assert_equal 1,   sr.fail_count
    assert_in_delta 0.5, sr.pass_rate, 0.001
  end

  def test_pass_rate_is_nil_when_no_passed_recorded
    klass = make_eval_class { record_case_result(metrics: { score: 0.9 }) }
    result = run_eval(klass)
    assert_nil result.subject_results.first.pass_rate
  end

  def test_pass_count_and_fail_count
    klass = make_eval_class do
      record_case_result(passed: current_case.id == 'case_01')
    end
    result = run_eval(klass)
    sr = result.subject_results.first
    assert_equal 1, sr.pass_count
    assert_equal 1, sr.fail_count
    assert_equal 0, sr.error_count
  end

  # ---------------------------------------------------------------------------
  # Metric aggregation
  # ---------------------------------------------------------------------------

  def test_average_metric_aggregated_correctly
    klass = make_eval_class do
      val = current_case.id == 'case_01' ? 1.0 : 0.0
      record_case_result(metrics: { exact_match: val })
    end
    klass.metric :exact_match, type: :average
    result = run_eval(klass)
    assert_in_delta 0.5, result.subject_results.first.metrics[:exact_match], 0.001
  end

  def test_sum_metric_aggregated_correctly
    klass = make_eval_class do
      record_case_result(metrics: { token_count: 10 })
    end
    klass.metric :token_count, type: :sum
    result = run_eval(klass)
    assert_equal 20, result.subject_results.first.metrics[:token_count]
  end

  def test_min_metric_aggregated_correctly
    klass = make_eval_class do
      val = current_case.id == 'case_01' ? 3.0 : 7.0
      record_case_result(metrics: { latency: val })
    end
    klass.metric :latency, type: :min
    result = run_eval(klass)
    assert_in_delta 3.0, result.subject_results.first.metrics[:latency], 0.001
  end

  def test_max_metric_aggregated_correctly
    klass = make_eval_class do
      val = current_case.id == 'case_01' ? 3.0 : 7.0
      record_case_result(metrics: { latency: val })
    end
    klass.metric :latency, type: :max
    result = run_eval(klass)
    assert_in_delta 7.0, result.subject_results.first.metrics[:latency], 0.001
  end

  def test_count_metric_aggregated_correctly
    klass = make_eval_class do
      record_case_result(metrics: { attempts: 1 })
    end
    klass.metric :attempts, type: :count
    result = run_eval(klass)
    assert_equal 2, result.subject_results.first.metrics[:attempts]
  end

  def test_metrics_absent_when_none_declared
    klass = make_eval_class { record_case_result(passed: true) }
    result = run_eval(klass)
    assert_equal({}, result.subject_results.first.metrics)
  end

  # ---------------------------------------------------------------------------
  # Subject results structure
  # ---------------------------------------------------------------------------

  def test_one_subject_result_per_subject
    klass = make_eval_class(subjects: [:a, :b]) { record_case_result }
    result = run_eval(klass)
    assert_equal 2, result.subject_results.length
    assert_equal [:a, :b], result.subject_results.map(&:subject_name)
  end

  def test_case_count_matches_dataset
    klass = make_eval_class { record_case_result }
    result = run_eval(klass)
    assert_equal 2, result.subject_results.first.case_count
  end

  # ---------------------------------------------------------------------------
  # Error handling
  # ---------------------------------------------------------------------------

  def test_error_propagates_by_default
    klass = make_eval_class { raise "boom" }
    assert_raises(RuntimeError) { run_eval(klass) }
  end

  def test_continue_on_error_records_error_and_continues
    case_ids = []
    klass = make_eval_class do
      case_ids << current_case.id
      raise "boom"
    end
    result = run_eval(klass, continue_on_error: true)
    assert_equal ['case_01', 'case_02'], case_ids
    sr = result.subject_results.first
    assert_equal 2, sr.error_count
    assert sr.case_results.all? { |r| r[:error]&.include?("boom") }
  end

  def test_continue_on_error_error_message_includes_class_and_message
    klass = make_eval_class { raise ArgumentError, "bad input" }
    result = run_eval(klass, continue_on_error: true)
    error_msg = result.subject_results.first.case_results.first[:error]
    assert_includes error_msg, "ArgumentError"
    assert_includes error_msg, "bad input"
  end
end
