require_relative '../test_helper'

class ResolveTest < Minitest::Test

  def test_resolves_pipeline
    Workbench::Pipeline.stub(:find, stub_pipeline) do
      result = Workbench.resolve('code_review')
      assert_equal 'code_review', result[:name]
      assert_equal 'pipeline',    result[:type]
    end
  end

  def test_resolves_task_when_no_pipeline_found
    Workbench::Pipeline.stub(:find, nil) do
      Workbench::Task.stub(:find, stub_task_class) do
        result = Workbench.resolve('analyze_code')
        assert_equal 'analyze_code', result[:name]
        assert_equal 'task',         result[:type]
      end
    end
  end

  def test_prefers_pipeline_over_task
    Workbench::Pipeline.stub(:find, stub_pipeline) do
      # Task.find should never be called — if it were, it would raise
      Workbench::Task.stub(:find, ->(_) { raise "should not be called" }) do
        result = Workbench.resolve('code_review')
        assert_equal 'pipeline', result[:type]
      end
    end
  end

  def test_raises_for_unknown_name
    Workbench::Pipeline.stub(:find, nil) do
      Workbench::Task.stub(:find, ->(_) { raise NameError }) do
        assert_raises(ArgumentError) { Workbench.resolve('nonexistent') }
      end
    end
  end

  def test_error_message_includes_name
    Workbench::Pipeline.stub(:find, nil) do
      Workbench::Task.stub(:find, ->(_) { raise NameError }) do
        error = assert_raises(ArgumentError) { Workbench.resolve('mystery_task') }
        assert_match 'mystery_task', error.message
      end
    end
  end

  private

  def stub_pipeline
    Object.new  # Pipeline.find returns a truthy object when found
  end

  def stub_task_class
    Class.new   # Task.find returns a class constant when found
  end
end
