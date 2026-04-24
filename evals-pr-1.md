# Evals: core runtime (PR 1 of 3)

Introduces first-class eval support to LLM Workbench. Developers can now define evals as Ruby classes, attach them to Tasks and Pipelines, run them against curated fixture datasets from the CLI, and receive both console output and persistent result artifacts.

After this PR, a developer can run:

```bash
workbench eval run --name parse_itinerary_email_basic
workbench eval run --subject parse_itinerary_email
```

And receive a per-case pass/fail breakdown, named metric aggregates, and written result files — without any new gem dependencies.

**Note:** This is the first of three PRs for the evals feature. The full plan is documented in `features/evals.md`.

## What's in this PR

### New command

| Command | Description |
|---------|-------------|
| `workbench eval run --name <name>` | Run a specific eval by name |
| `workbench eval run --subject <name>` | Run all evals attached to a subject via `evaluated_by` |

Both forms accept `--continue-on-error` to record case-level exceptions and continue rather than halting the run.

### New classes

- **`Workbench::Eval`** — base class for eval definitions; class-level DSL (`evaluates`, `dataset`, `metric`), subclass registry via `inherited` hook, `find`/`for_subject` class methods, and `run_subject`/`record_case_result` instance helpers
- **`Workbench::Dataset`** — YAML-backed dataset loader; discovers cases from `fixtures/` using default rules (files-as-cases or directories-as-cases), with `include`/`ignore` glob filtering, configurable sort order, and hidden/junk file exclusion
- **`Workbench::EvalCase`** — normalized case value object exposing `id`, `group_name`, `root_path`, `files`, `inputs`, `outputs`
- **`Workbench::EvalFile`** — normalized file value object exposing `name`, `path`, `relative_path`, `read`
- **`Workbench::EvalRunner`** — orchestrates the full eval lifecycle; iterates subjects × cases, calls `setup`/`teardown` hooks, aggregates metrics by declared type, computes `pass_rate` from `passed:` booleans, returns a structured `EvalRunResult`
- **`Workbench::EvalResultWriter`** — writes `summary.txt` and `run.json` after each run; output path is `eval_results/YYYY-MM-DD/<eval_name>/`, with `_2`/`_3` suffixes on same-day collisions

### DSL additions

`evaluated_by` is added to both `Task` (Ruby class-level DSL) and `Pipeline` (parsed from the YAML `evaluated_by:` field), creating a bidirectional association between subjects and their evals.

### Writing an eval

```ruby
class ParseItineraryEmailBasic < Workbench::Eval
  evaluates :parse_itinerary_email
  dataset   :golden_emails
  metric    :exact_match          # type: :average is the default

  def run
    result = run_subject(current_subject, inputs: { email: current_case.files.first.read })
    exact  = result[:bookings] == expected
    record_case_result(
      passed:  exact,
      metrics: { exact_match: exact ? 1.0 : 0.0 }
    )
  end
end
```

Attach it to the subject:

```ruby
class ParseItineraryEmail < Workbench::Task
  evaluated_by :parse_itinerary_email_basic
end
```

### Dataset definition

Datasets are declared in `datasets/` and resolve fixture files from `fixtures/`:

```yaml
# datasets/golden_emails.yml
name: golden_emails
ignore:
  - "*.rb"
sort: asc
```

Default discovery rules: if the fixture directory contains subdirectories, each non-empty subdirectory becomes a case (its files are the case payload). If the directory contains only files, each file becomes a case. Full `directory: case/group` structural overrides are in PR 2.

### Metric types

| Type | Aggregation |
|------|-------------|
| `:average` | Mean of per-case values (default) |
| `:sum` | Sum of per-case values |
| `:count` | Count of non-nil per-case values |
| `:min` | Minimum per-case value |
| `:max` | Maximum per-case value |

`pass_rate` is always computed automatically from `passed:` booleans and reported separately from named metrics. `passed:` is optional — evals that produce only scored metrics can omit it.

### Result artifacts

Each run writes two files to `eval_results/YYYY-MM-DD/<eval_name>/`:

- **`summary.txt`** — fixed-width human-readable output including run ID, timestamps, pass rate, metric values, and FAILED/ERROR case entries; suitable for terminal review or git diffing
- **`run.json`** — normalized machine-readable output structured for future SQLite ingestion; includes per-subject counts, pass rate, metric aggregates, and full per-case detail

### Error handling

By default the runner halts on any uncaught exception from `run`. With `--continue-on-error`, the exception is captured as a case-level error (including class and message), the run continues, and error cases are reported in the summary alongside failures.

### Testing

93 new tests across 4 new test files:

| File | Coverage |
|------|----------|
| `test/workbench/eval_test.rb` | Eval DSL, registry, `find`/`for_subject`, `record_case_result`, `evaluated_by` on Task and Pipeline |
| `test/workbench/dataset_test.rb` | YAML loading, files-as-cases, dirs-as-cases, include/ignore, sort, hidden/junk exclusion, zero-cases error, `EvalFile` API |
| `test/workbench/eval_runner_test.rb` | Lifecycle ordering, multi-subject sequencing, all five metric types, pass rate, `continue_on_error` |
| `test/workbench/eval_result_writer_test.rb` | Output dir structure, date stamping, collision suffix, `run.json` structure, `summary.txt` content |

All pipeline execution in runner tests is stubbed via eval subclasses that call `record_case_result` directly.

### No new dependencies

This feature uses only Ruby stdlib and existing workbench dependencies (`thor`, `activesupport`).

## What's NOT in this PR

- **Advanced dataset discovery** (PR 2) — `directory: case/group` structural modes, `case.inputs`/`case.outputs` hints, `group`/`case` include/ignore filters, `workbench eval dataset inspect`
- **CLI ergonomics** (PR 3) — `workbench eval create`, `workbench eval link`, `workbench eval check`

For details on these next phases, see `features/evals.md`.
