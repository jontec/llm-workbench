require_relative '../test_helper'

class InputValidatorTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def pipeline_with_tasks(*task_specs)
    task_list = task_specs.map do |input_defs, output_defs|
      task_class = Class.new do
        define_singleton_method(:input_definitions)  { input_defs || {} }
        define_singleton_method(:output_definitions) { output_defs || {} }
      end
      stub = Object.new
      stub.define_singleton_method(:class) { task_class }
      stub
    end
    pipeline = Object.new
    pipeline.define_singleton_method(:task_list) { task_list }
    pipeline
  end

  # ---------------------------------------------------------------------------
  # external_inputs
  # ---------------------------------------------------------------------------

  def test_single_task_all_inputs_are_external
    pipeline = pipeline_with_tasks([{ name: {}, count: {} }, {}])
    validator = Workbench::InputValidator.new(pipeline)
    assert_equal %i[name count].to_set, validator.external_inputs.keys.to_set
  end

  def test_input_satisfied_by_prior_task_output_is_not_external
    # Task A outputs :summary; Task B takes :summary as input
    pipeline = pipeline_with_tasks(
      [{ query: {} },          { summary: {} }],   # Task A
      [{ summary: {}, id: {} }, {}]                 # Task B
    )
    validator = Workbench::InputValidator.new(pipeline)
    # :summary is produced by Task A, so only :query and :id are external
    assert_equal %i[query id].to_set, validator.external_inputs.keys.to_set
  end

  def test_no_inputs_returns_empty_hash
    pipeline = pipeline_with_tasks([{}, {}])
    assert_empty Workbench::InputValidator.new(pipeline).external_inputs
  end

  # ---------------------------------------------------------------------------
  # validate
  # ---------------------------------------------------------------------------

  def test_required_input_present_returns_no_errors
    pipeline = pipeline_with_tasks([{ name: {} }, {}])
    errors = Workbench::InputValidator.new(pipeline).validate('name' => 'Alice')
    assert_empty errors
  end

  def test_required_input_missing_returns_error
    pipeline = pipeline_with_tasks([{ name: {} }, {}])
    errors = Workbench::InputValidator.new(pipeline).validate({})
    assert_includes errors, 'name'
  end

  def test_optional_input_missing_returns_no_errors
    pipeline = pipeline_with_tasks([{ name: { optional: true } }, {}])
    errors = Workbench::InputValidator.new(pipeline).validate({})
    assert_empty errors
  end

  def test_multiple_missing_required_inputs_all_reported
    pipeline = pipeline_with_tasks([{ name: {}, age: {} }, {}])
    errors = Workbench::InputValidator.new(pipeline).validate({})
    assert_includes errors, 'name'
    assert_includes errors, 'age'
  end

  def test_internally_satisfied_input_not_validated_against_body
    pipeline = pipeline_with_tasks(
      [{ query: {} },    { summary: {} }],
      [{ summary: {} },  {}]
    )
    # body only provides :query; :summary comes from Task A's output
    errors = Workbench::InputValidator.new(pipeline).validate('query' => 'hello')
    assert_empty errors
  end

  def test_pipeline_with_no_tasks_is_valid
    pipeline = Object.new
    pipeline.define_singleton_method(:task_list) { [] }
    assert_empty Workbench::InputValidator.new(pipeline).validate({})
  end
end
