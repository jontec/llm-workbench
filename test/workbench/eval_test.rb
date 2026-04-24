require_relative '../test_helper'

class EvalTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Class-level DSL
  # ---------------------------------------------------------------------------

  def test_evaluates_stores_subject_names
    klass = fresh_eval_class
    klass.evaluates :parse_itinerary_email
    klass.evaluates :parse_booking_email
    assert_equal [:parse_itinerary_email, :parse_booking_email], klass.subject_names
  end

  def test_subject_names_defaults_to_empty_array
    klass = fresh_eval_class
    assert_equal [], klass.subject_names
  end

  def test_dataset_stores_name
    klass = fresh_eval_class
    klass.dataset :golden_emails
    assert_equal :golden_emails, klass.dataset_name
  end

  def test_metric_stores_name_and_default_type
    klass = fresh_eval_class
    klass.metric :exact_match
    assert_equal({ type: :average }, klass.metric_definitions[:exact_match])
  end

  def test_metric_stores_explicit_type
    klass = fresh_eval_class
    klass.metric :total_score, type: :sum
    assert_equal({ type: :sum }, klass.metric_definitions[:total_score])
  end

  def test_metric_raises_on_unknown_type
    klass = fresh_eval_class
    assert_raises(ArgumentError) { klass.metric :bad, type: :bogus }
  end

  def test_metric_definitions_defaults_to_nil
    klass = fresh_eval_class
    assert_nil klass.metric_definitions
  end

  # ---------------------------------------------------------------------------
  # eval_name
  # ---------------------------------------------------------------------------

  def test_eval_name_underscores_class_name
    stub_class = Class.new(Workbench::Eval)
    stub_class.define_singleton_method(:name) { "ParseItineraryEmailBasicEval" }
    assert_equal :parse_itinerary_email_basic_eval, stub_class.eval_name
  end

  def test_eval_name_strips_module_prefix
    stub_class = Class.new(Workbench::Eval)
    stub_class.define_singleton_method(:name) { "Workbench::SomeEval" }
    assert_equal :some_eval, stub_class.eval_name
  end

  # ---------------------------------------------------------------------------
  # inherited registry
  # ---------------------------------------------------------------------------

  def test_subclass_appears_in_registry
    klass = fresh_eval_class
    assert_includes Workbench::Eval.subclasses, klass
  end

  def test_find_returns_matching_subclass
    klass = fresh_named_eval_class("FindableEval")
    found = Workbench::Eval.subclasses.find { |s| s.eval_name == :findable_eval }
    assert_equal klass, found
  end

  def test_for_subject_returns_evals_with_matching_evaluates
    klass = fresh_eval_class
    klass.evaluates :my_pipeline
    klass.evaluates :other_pipeline

    matches = Workbench::Eval.subclasses.select { |s| s.subject_names.include?(:my_pipeline) }
    assert_includes matches, klass
  end

  # ---------------------------------------------------------------------------
  # Instance helpers
  # ---------------------------------------------------------------------------

  def test_run_raises_not_implemented
    instance = Workbench::Eval.new
    assert_raises(NotImplementedError) { instance.run }
  end

  def test_record_case_result_accumulates_results
    instance = Workbench::Eval.new
    instance.current_case    = stub_case("case_01")
    instance.current_subject = :my_pipeline

    instance.record_case_result(passed: true, metrics: { exact_match: 1.0 })
    instance.record_case_result(passed: false, metrics: { exact_match: 0.0 })

    assert_equal 2, instance.case_results.length
    assert_equal "case_01", instance.case_results.first[:case_id]
    assert_equal :my_pipeline, instance.case_results.first[:subject]
    assert_equal true,  instance.case_results.first[:passed]
    assert_equal 1.0,   instance.case_results.first[:metrics][:exact_match]
    assert_equal false, instance.case_results.last[:passed]
  end

  def test_record_case_result_passed_is_optional
    instance = Workbench::Eval.new
    instance.current_case = stub_case("case_01")
    instance.record_case_result(metrics: { rubric_score: 0.8 })
    assert_nil instance.case_results.first[:passed]
  end

  def test_case_results_defaults_to_empty_array
    instance = Workbench::Eval.new
    assert_equal [], instance.case_results
  end

  # ---------------------------------------------------------------------------
  # evaluated_by on Task
  # ---------------------------------------------------------------------------

  def test_task_evaluated_by_stores_eval_names
    task_class = Class.new(Workbench::Task)
    task_class.evaluated_by :my_eval
    task_class.evaluated_by :other_eval
    assert_equal [:my_eval, :other_eval], task_class.eval_names
  end

  def test_task_eval_names_defaults_to_empty_array
    task_class = Class.new(Workbench::Task)
    assert_equal [], task_class.eval_names
  end

  # ---------------------------------------------------------------------------
  # evaluated_by on Pipeline (via YAML)
  # ---------------------------------------------------------------------------

  def test_pipeline_parses_evaluated_by_from_yaml
    Dir.mktmpdir do |dir|
      pipeline_dir = File.join(dir, 'pipelines')
      task_dir     = File.join(dir, 'tasks')
      FileUtils.mkdir_p(pipeline_dir)
      FileUtils.mkdir_p(task_dir)

      # Minimal task so the pipeline can index it
      task_file = File.join(task_dir, 'echo_task.rb')
      File.write(task_file, <<~RUBY)
        class EchoTask < Workbench::Task
          def run; end
        end
      RUBY
      require task_file

      yaml_path = File.join(pipeline_dir, 'my_pipeline.yml')
      File.write(yaml_path, <<~YAML)
        name: my_pipeline
        evaluated_by:
          - my_eval
          - other_eval
        tasks:
          - name: echo_task
      YAML

      pipeline = Workbench::Pipeline.new(yaml_path)
      assert_equal [:my_eval, :other_eval], pipeline.eval_names
    end
  end

  def test_pipeline_eval_names_defaults_to_empty_array
    Dir.mktmpdir do |dir|
      task_dir = File.join(dir, 'tasks')
      FileUtils.mkdir_p(task_dir)

      task_file = File.join(task_dir, 'echo_task2.rb')
      File.write(task_file, <<~RUBY)
        class EchoTask2 < Workbench::Task
          def run; end
        end
      RUBY
      require task_file

      yaml_path = File.join(dir, 'no_evals_pipeline.yml')
      File.write(yaml_path, <<~YAML)
        name: no_evals_pipeline
        tasks:
          - name: echo_task2
      YAML

      pipeline = Workbench::Pipeline.new(yaml_path)
      assert_equal [], pipeline.eval_names
    end
  end

  private

  def fresh_eval_class
    Class.new(Workbench::Eval)
  end

  def fresh_named_eval_class(name)
    klass = Class.new(Workbench::Eval)
    klass.define_singleton_method(:name) { name }
    klass
  end

  def stub_case(id)
    Workbench::EvalCase.new(id: id, root_path: '/tmp', files: [])
  end
end
