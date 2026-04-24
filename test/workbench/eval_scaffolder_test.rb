require_relative '../test_helper'
require 'fileutils'
require 'tmpdir'

class EvalScaffolderTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def with_project
    Dir.mktmpdir do |dir|
      %w[evals datasets tasks pipelines].each { |d| FileUtils.mkdir_p(File.join(dir, d)) }
      yield dir
    end
  end

  def scaffolder(dir, name, subjects)
    Workbench::EvalScaffolder.new(name, subjects,
      eval_dir:     File.join(dir, 'evals'),
      dataset_dir:  File.join(dir, 'datasets'),
      task_dir:     File.join(dir, 'tasks'),
      pipeline_dir: File.join(dir, 'pipelines')
    )
  end

  def write_task(dir, name)
    path = File.join(dir, 'tasks', "#{name}.rb")
    File.write(path, "class #{name.split('_').map(&:capitalize).join} < Workbench::Task\n  def run; end\nend\n")
    path
  end

  def write_pipeline(dir, name)
    path = File.join(dir, 'pipelines', "#{name}.yml")
    File.write(path, "name: #{name}\ntasks:\n  - name: echo\n")
    path
  end

  def capture_output(&block)
    capture_io(&block).first
  end

  # ---------------------------------------------------------------------------
  # create — file generation
  # ---------------------------------------------------------------------------

  def test_create_writes_eval_file
    with_project do |dir|
      write_task(dir, 'parse_email')
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      assert File.exist?(File.join(dir, 'evals', 'parse_email_basic.rb'))
    end
  end

  def test_create_eval_file_contains_class_definition
    with_project do |dir|
      write_task(dir, 'parse_email')
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      content = File.read(File.join(dir, 'evals', 'parse_email_basic.rb'))
      assert_includes content, 'class ParseEmailBasic < Workbench::Eval'
    end
  end

  def test_create_eval_file_contains_evaluates_declaration
    with_project do |dir|
      write_task(dir, 'parse_email')
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      content = File.read(File.join(dir, 'evals', 'parse_email_basic.rb'))
      assert_includes content, 'evaluates :parse_email'
    end
  end

  def test_create_eval_file_contains_dataset_declaration
    with_project do |dir|
      write_task(dir, 'parse_email')
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      content = File.read(File.join(dir, 'evals', 'parse_email_basic.rb'))
      assert_includes content, 'dataset :parse_email_basic'
    end
  end

  def test_create_writes_dataset_stub
    with_project do |dir|
      write_task(dir, 'parse_email')
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      assert File.exist?(File.join(dir, 'datasets', 'parse_email_basic.yml'))
    end
  end

  def test_create_dataset_stub_contains_name
    with_project do |dir|
      write_task(dir, 'parse_email')
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      content = File.read(File.join(dir, 'datasets', 'parse_email_basic.yml'))
      assert_includes content, 'name: parse_email_basic'
    end
  end

  def test_create_does_not_overwrite_existing_dataset_stub
    with_project do |dir|
      write_task(dir, 'parse_email')
      dataset_path = File.join(dir, 'datasets', 'parse_email_basic.yml')
      File.write(dataset_path, "name: parse_email_basic\npath: custom\n")
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      assert_includes File.read(dataset_path), 'path: custom'
    end
  end

  # ---------------------------------------------------------------------------
  # create — multiple subjects
  # ---------------------------------------------------------------------------

  def test_create_with_multiple_subjects_patches_all
    with_project do |dir|
      write_task(dir, 'parse_email')
      write_task(dir, 'parse_booking')
      s = scaffolder(dir, 'shared_check', ['parse_email', 'parse_booking'])
      capture_output { s.create }
      content = File.read(File.join(dir, 'evals', 'shared_check.rb'))
      assert_includes content, 'evaluates :parse_email'
      assert_includes content, 'evaluates :parse_booking'
    end
  end

  # ---------------------------------------------------------------------------
  # create — patching task (Ruby) subjects
  # ---------------------------------------------------------------------------

  def test_create_patches_task_with_evaluated_by
    with_project do |dir|
      path = write_task(dir, 'parse_email')
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      assert_includes File.read(path), 'evaluated_by :parse_email_basic'
    end
  end

  def test_create_does_not_duplicate_evaluated_by_on_task
    with_project do |dir|
      path = write_task(dir, 'parse_email')
      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.create }
      capture_output { s.create }
      count = File.read(path).scan('evaluated_by :parse_email_basic').length
      assert_equal 1, count
    end
  end

  # ---------------------------------------------------------------------------
  # create — patching pipeline (YAML) subjects
  # ---------------------------------------------------------------------------

  def test_create_patches_pipeline_with_evaluated_by
    with_project do |dir|
      path = write_pipeline(dir, 'my_pipeline')
      s = scaffolder(dir, 'pipeline_check', ['my_pipeline'])
      capture_output { s.create }
      content = File.read(path)
      assert_includes content, 'evaluated_by'
      assert_includes content, 'pipeline_check'
    end
  end

  def test_create_does_not_duplicate_evaluated_by_on_pipeline
    with_project do |dir|
      path = write_pipeline(dir, 'my_pipeline')
      s = scaffolder(dir, 'pipeline_check', ['my_pipeline'])
      capture_output { s.create }
      capture_output { s.create }
      count = File.read(path).scan('pipeline_check').length
      assert_equal 1, count
    end
  end

  # ---------------------------------------------------------------------------
  # create — error handling
  # ---------------------------------------------------------------------------

  def test_create_returns_error_for_unknown_subject
    with_project do |dir|
      s = scaffolder(dir, 'my_check', ['nonexistent_subject'])
      errors = s.create
      assert errors.any?
      assert errors.first.include?('nonexistent_subject')
    end
  end

  # ---------------------------------------------------------------------------
  # link
  # ---------------------------------------------------------------------------

  def test_link_patches_subject_and_eval
    with_project do |dir|
      task_path = write_task(dir, 'parse_email')
      eval_path = File.join(dir, 'evals', 'parse_email_basic.rb')
      File.write(eval_path, "class ParseEmailBasic < Workbench::Eval\n  dataset :x\nend\n")

      s = scaffolder(dir, 'parse_email_basic', ['parse_email'])
      capture_output { s.link }

      assert_includes File.read(task_path), 'evaluated_by :parse_email_basic'
      assert_includes File.read(eval_path), 'evaluates :parse_email'
    end
  end

  def test_link_errors_when_eval_file_missing
    with_project do |dir|
      write_task(dir, 'parse_email')
      s = scaffolder(dir, 'nonexistent_eval', ['parse_email'])
      errors = s.link
      assert errors.any?
      assert errors.first.include?('does not exist')
    end
  end

  def test_link_does_not_create_eval_file
    with_project do |dir|
      write_task(dir, 'parse_email')
      s = scaffolder(dir, 'nonexistent_eval', ['parse_email'])
      capture_output { s.link }
      refute File.exist?(File.join(dir, 'evals', 'nonexistent_eval.rb'))
    end
  end
end
