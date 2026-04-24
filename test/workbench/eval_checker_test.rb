require_relative '../test_helper'
require 'fileutils'
require 'tmpdir'

class EvalCheckerTest < Minitest::Test

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  def with_project
    Dir.mktmpdir do |dir|
      %w[evals datasets tasks pipelines fixtures].each { |d| FileUtils.mkdir_p(File.join(dir, d)) }
      yield dir
    end
  end

  def checker(dir)
    Workbench::EvalChecker.new(
      eval_dir:     File.join(dir, 'evals'),
      task_dir:     File.join(dir, 'tasks'),
      pipeline_dir: File.join(dir, 'pipelines'),
      dataset_dir:  File.join(dir, 'datasets'),
      fixtures_dir: File.join(dir, 'fixtures')
    )
  end

  def write_eval(dir, name, evaluates: nil, dataset: nil)
    class_name = name.to_s.split('_').map(&:capitalize).join
    evaluates_line = evaluates ? "  evaluates :#{evaluates}\n" : ""
    dataset_line   = dataset   ? "  dataset :#{dataset}\n"   : ""
    path = File.join(dir, 'evals', "#{name}.rb")
    File.write(path, "class #{class_name} < Workbench::Eval\n#{evaluates_line}#{dataset_line}end\n")
  end

  def write_task(dir, name, evaluated_by: nil)
    eb_line = evaluated_by ? "  evaluated_by :#{evaluated_by}\n" : ""
    path = File.join(dir, 'tasks', "#{name}.rb")
    File.write(path, "class #{name.split('_').map(&:capitalize).join} < Workbench::Task\n#{eb_line}  def run; end\nend\n")
  end

  def write_pipeline(dir, name, evaluated_by: nil)
    eb = evaluated_by ? "evaluated_by:\n  - #{evaluated_by}\n" : ""
    path = File.join(dir, 'pipelines', "#{name}.yml")
    File.write(path, "name: #{name}\n#{eb}tasks:\n  - name: echo\n")
  end

  def write_dataset(dir, dataset_name, fixture_name: nil)
    fixture_name ||= dataset_name
    path = File.join(dir, 'datasets', "#{dataset_name}.yml")
    File.write(path, "name: #{dataset_name}\npath: #{fixture_name}\n")
    fixture_dir = File.join(dir, 'fixtures', fixture_name)
    FileUtils.mkdir_p(fixture_dir)
    File.write(File.join(fixture_dir, 'case.txt'), 'data')
  end

  def issue_types(issues)
    issues.map(&:type)
  end

  # ---------------------------------------------------------------------------
  # Clean project — no issues
  # ---------------------------------------------------------------------------

  def test_no_issues_when_project_is_clean
    with_project do |dir|
      write_task(dir, 'parse_email', evaluated_by: 'parse_email_basic')
      write_eval(dir, 'parse_email_basic', evaluates: 'parse_email', dataset: 'golden_emails')
      write_dataset(dir, 'golden_emails')
      issues = checker(dir).check
      assert_empty issues
    end
  end

  def test_exits_cleanly_with_empty_project
    with_project do |dir|
      issues = checker(dir).check
      assert_empty issues
    end
  end

  # ---------------------------------------------------------------------------
  # [missing-eval]
  # ---------------------------------------------------------------------------

  def test_missing_eval_detected_for_task
    with_project do |dir|
      write_task(dir, 'parse_email', evaluated_by: 'nonexistent_eval')
      issues = checker(dir).check
      assert_includes issue_types(issues), :missing_eval
    end
  end

  def test_missing_eval_includes_subject_and_eval_name
    with_project do |dir|
      write_task(dir, 'parse_email', evaluated_by: 'nonexistent_eval')
      issue = checker(dir).check.find { |i| i.type == :missing_eval }
      assert_equal :nonexistent_eval, issue.details[:eval]
      assert_equal :parse_email,      issue.details[:subject]
    end
  end

  def test_missing_eval_detected_for_pipeline
    with_project do |dir|
      write_pipeline(dir, 'my_pipeline', evaluated_by: 'nonexistent_eval')
      issues = checker(dir).check
      assert_includes issue_types(issues), :missing_eval
    end
  end

  def test_no_missing_eval_when_eval_exists
    with_project do |dir|
      write_task(dir, 'parse_email', evaluated_by: 'parse_email_basic')
      write_eval(dir, 'parse_email_basic', evaluates: 'parse_email', dataset: 'golden_emails')
      write_dataset(dir, 'golden_emails')
      issues = checker(dir).check
      refute_includes issue_types(issues), :missing_eval
    end
  end

  # ---------------------------------------------------------------------------
  # [missing-subject]
  # ---------------------------------------------------------------------------

  def test_missing_subject_detected
    with_project do |dir|
      write_eval(dir, 'parse_email_basic', evaluates: 'nonexistent_subject')
      issues = checker(dir).check
      assert_includes issue_types(issues), :missing_subject
    end
  end

  def test_missing_subject_includes_eval_and_subject_name
    with_project do |dir|
      write_eval(dir, 'parse_email_basic', evaluates: 'nonexistent_subject')
      issue = checker(dir).check.find { |i| i.type == :missing_subject }
      assert_equal :nonexistent_subject,  issue.details[:subject]
      assert_equal :parse_email_basic,    issue.details[:eval]
    end
  end

  def test_no_missing_subject_when_task_exists
    with_project do |dir|
      write_task(dir, 'parse_email', evaluated_by: 'parse_email_basic')
      write_eval(dir, 'parse_email_basic', evaluates: 'parse_email', dataset: 'golden_emails')
      write_dataset(dir, 'golden_emails')
      issues = checker(dir).check
      refute_includes issue_types(issues), :missing_subject
    end
  end

  def test_no_missing_subject_when_pipeline_exists
    with_project do |dir|
      write_pipeline(dir, 'my_pipeline', evaluated_by: 'my_check')
      write_eval(dir, 'my_check', evaluates: 'my_pipeline', dataset: 'golden_emails')
      write_dataset(dir, 'golden_emails')
      issues = checker(dir).check
      refute_includes issue_types(issues), :missing_subject
    end
  end

  # ---------------------------------------------------------------------------
  # [orphaned-eval]
  # ---------------------------------------------------------------------------

  def test_orphaned_eval_detected_when_no_links
    with_project do |dir|
      write_eval(dir, 'unlinked_check')  # no evaluates, no evaluated_by from any subject
      issues = checker(dir).check
      assert_includes issue_types(issues), :orphaned_eval
    end
  end

  def test_no_orphan_when_eval_declares_evaluates
    with_project do |dir|
      write_task(dir, 'parse_email')
      write_eval(dir, 'parse_email_basic', evaluates: 'parse_email', dataset: 'golden_emails')
      write_dataset(dir, 'golden_emails')
      issues = checker(dir).check
      refute_includes issue_types(issues), :orphaned_eval
    end
  end

  def test_no_orphan_when_subject_declares_evaluated_by
    with_project do |dir|
      write_task(dir, 'parse_email', evaluated_by: 'parse_email_basic')
      write_eval(dir, 'parse_email_basic', dataset: 'golden_emails')
      write_dataset(dir, 'golden_emails')
      issues = checker(dir).check
      refute_includes issue_types(issues), :orphaned_eval
    end
  end

  # ---------------------------------------------------------------------------
  # [broken-dataset]
  # ---------------------------------------------------------------------------

  def test_broken_dataset_when_dataset_file_missing
    with_project do |dir|
      write_task(dir, 'parse_email', evaluated_by: 'parse_email_basic')
      write_eval(dir, 'parse_email_basic', evaluates: 'parse_email', dataset: 'missing_dataset')
      issues = checker(dir).check
      assert_includes issue_types(issues), :broken_dataset
    end
  end

  def test_broken_dataset_includes_eval_and_dataset_name
    with_project do |dir|
      write_eval(dir, 'parse_email_basic', evaluates: 'parse_email', dataset: 'missing_dataset')
      write_task(dir, 'parse_email', evaluated_by: 'parse_email_basic')
      issue = checker(dir).check.find { |i| i.type == :broken_dataset }
      assert_equal :parse_email_basic, issue.details[:eval]
      assert_equal :missing_dataset,   issue.details[:dataset]
    end
  end

  def test_no_broken_dataset_when_dataset_valid
    with_project do |dir|
      write_task(dir, 'parse_email', evaluated_by: 'parse_email_basic')
      write_eval(dir, 'parse_email_basic', evaluates: 'parse_email', dataset: 'golden_emails')
      write_dataset(dir, 'golden_emails')
      issues = checker(dir).check
      refute_includes issue_types(issues), :broken_dataset
    end
  end

  def test_broken_dataset_when_zero_cases
    with_project do |dir|
      write_eval(dir, 'parse_email_basic', evaluates: 'parse_email', dataset: 'empty_set')
      write_task(dir, 'parse_email', evaluated_by: 'parse_email_basic')
      # Dataset YAML exists but fixture dir is empty
      File.write(File.join(dir, 'datasets', 'empty_set.yml'), "name: empty_set\n")
      FileUtils.mkdir_p(File.join(dir, 'fixtures', 'empty_set'))
      issues = checker(dir).check
      assert_includes issue_types(issues), :broken_dataset
    end
  end

  # ---------------------------------------------------------------------------
  # format_issue
  # ---------------------------------------------------------------------------

  def test_format_missing_eval
    issue = Workbench::EvalChecker::Issue.new(type: :missing_eval, details: { subject: :my_task, eval: :my_check })
    msg   = Workbench::EvalChecker.format_issue(issue)
    assert_includes msg, '[missing-eval]'
    assert_includes msg, 'my_task'
    assert_includes msg, 'my_check'
  end

  def test_format_missing_subject
    issue = Workbench::EvalChecker::Issue.new(type: :missing_subject, details: { eval: :my_check, subject: :missing })
    msg   = Workbench::EvalChecker.format_issue(issue)
    assert_includes msg, '[missing-subject]'
    assert_includes msg, 'my_check'
    assert_includes msg, 'missing'
  end

  def test_format_orphaned_eval
    issue = Workbench::EvalChecker::Issue.new(type: :orphaned_eval, details: { eval: :lonely_check })
    msg   = Workbench::EvalChecker.format_issue(issue)
    assert_includes msg, '[orphaned-eval]'
    assert_includes msg, 'lonely_check'
  end

  def test_format_broken_dataset
    issue = Workbench::EvalChecker::Issue.new(type: :broken_dataset, details: { eval: :my_check, dataset: :bad_ds, error: 'not found' })
    msg   = Workbench::EvalChecker.format_issue(issue)
    assert_includes msg, '[broken-dataset]'
    assert_includes msg, 'my_check'
    assert_includes msg, 'bad_ds'
  end
end
