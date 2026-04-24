# Feature: Evals for LLM Workbench

## Overview

This feature adds first-class evaluation support to LLM Workbench. Developers can attach evals to Tasks and Pipelines, define them as reusable Ruby classes, run them from the CLI against curated datasets, and receive both machine-readable and human-readable result artifacts.

Evals follow Workbench's existing conventions: declarative DSL on subject classes, Ruby classes for logic, YAML-backed datasets, filesystem-first project structure.

## Build Plan

Development happens on a single `feature/evals` branch. Three PRs target `main` in sequence.

| PR | Phases | Description |
|----|--------|-------------|
| **PR 1** | 1, 2, 3 | Core runtime: `Workbench::Eval`, `Workbench::Dataset`, `Workbench::EvalRunner`, basic case discovery, `workbench eval run`, console output, result artifacts. Mergeable when a user can write an eval, point it at a dataset, run it, and get results. |
| **PR 2** | 4, 5 | Full dataset discovery: `directory: case/group`, `case.inputs`/`case.outputs` hints, `group`/`case` include/ignore filters, `workbench eval dataset inspect`. |
| **PR 3** | 6 | CLI ergonomics: `workbench eval create`, `workbench eval link`, `workbench eval check`. |

## CLI Interface

```bash
workbench eval run [--name <eval_name>] [--subject <subject_name>]
workbench eval create <name> --for <subject>[,<subject>]
workbench eval link <name> --for <subject>[,<subject>]
workbench eval check
workbench eval dataset inspect <dataset_name>
```

### `eval run` Options

| Flag | Description |
|------|-------------|
| `--name` | Run a specific eval by name |
| `--subject` | Run all evals attached to a subject (via `evaluated_by`) |

Exactly one of `--name` or `--subject` must be provided.

### `eval create` Options

| Flag | Description |
|------|-------------|
| `--for` | Subject name(s), comma-separated |

### `eval check` Checks

| Code | Description |
|------|-------------|
| `[missing-eval]` | An `evaluated_by` reference cannot be resolved to an eval file |
| `[missing-subject]` | An `evaluates` declaration cannot be resolved to a task or pipeline |
| `[orphaned-eval]` | An eval file exists but no subject declares `evaluated_by` for it and the eval itself does not declare `evaluates` |
| `[broken-dataset]` | An eval references a dataset that cannot be resolved or discovers zero cases |

### Examples

```bash
# Run a named eval
workbench eval run --name parse_itinerary_email_basic

# Run all evals attached to a subject
workbench eval run --subject parse_itinerary_email

# Scaffold a new eval and dataset stub, patch the subject
workbench eval create parse_itinerary_email_basic --for parse_itinerary_email

# Link an existing eval to one or more subjects
workbench eval link shared_contract_eval --for parse_itinerary_email,parse_booking_email

# Validate eval linkage across the project
workbench eval check

# Debug dataset discovery
workbench eval dataset inspect golden_emails
```

## Key Data Model (Reference)

### `Workbench::Eval` (base class)

```ruby
class ParseItineraryEmailBasicEval < Workbench::Eval
  evaluates :parse_itinerary_email          # repeatable; drives --subject lookup
  dataset   :golden_emails
  metric    :exact_match                    # type: :average is default
  metric    :rubric_score, type: :average

  def run
    result = run_subject(current_subject, inputs: current_case.inputs)
    exact  = result[:bookings] == current_case.outputs.first&.read
    record_case_result(
      passed:  exact,
      metrics: { exact_match: exact ? 1.0 : 0.0 }
    )
  end
end
```

### DSL summary

| Method | Where | Meaning |
|--------|-------|---------|
| `evaluates :name` | Eval class | Subject this eval covers (repeatable) |
| `dataset :name` | Eval class | Dataset to use for case discovery |
| `metric :name, type:` | Eval class | Named metric; `:average` is default type |
| `evaluated_by :name` | Task / Pipeline class | Attach an eval to this subject (repeatable) |

### `run` method contract

`run` is called once per (subject, case) pair. Before each call the runner sets:

- `current_subject` — the subject name symbol being evaluated
- `current_case` — the `Workbench::EvalCase` for this iteration

Available instance helpers:

| Helper | Description |
|--------|-------------|
| `run_subject(subject, inputs: {})` | Resolve and run the subject; returns the pipeline's full context hash |
| `record_case_result(passed: nil, metrics: {}, outputs: {}, error: nil)` | Record the result for this case; `passed:` is optional |
| `current_subject` | The subject name being evaluated |
| `current_case` | The current `EvalCase` |

`setup` and `teardown` instance methods, if defined, are called once before and after the full eval run (across all subjects and cases).

### Metric types

| Type | Aggregation |
|------|-------------|
| `:average` | Mean of per-case values (default) |
| `:sum` | Sum of per-case values |
| `:count` | Count of non-nil per-case values |
| `:min` | Minimum per-case value |
| `:max` | Maximum per-case value |

`pass_rate` is a **built-in statistic** computed automatically from per-case `passed:` booleans. It is reported separately from named metrics and does not need to be declared with `metric`.

### `Workbench::EvalCase` API

```ruby
current_case.id            # String — deterministic case identifier
current_case.group_name    # String or nil — group name for grouped datasets
current_case.root_path     # Pathname — filesystem root of this case
current_case.files         # Array<EvalFile> — all discovered files
current_case.inputs        # Array<EvalFile> — files matched by case.inputs hints
current_case.outputs       # Array<EvalFile> — files matched by case.outputs hints
```

### `Workbench::EvalFile` API

```ruby
file.name           # String — filename
file.path           # Pathname — absolute path
file.relative_path  # String — path relative to case root
file.read           # String — file contents
```

## Implementation Plan

### Phase 1: Core Data Model

**1. `Workbench::Eval` base class** (`lib/workbench/eval.rb`)

- Class-level DSL: `evaluates`, `dataset`, `metric` (stores name + options)
- Class-level registry via `inherited` hook — collects all subclasses on `require`
- `Eval.all` — globs `evals/**/*.rb`, requires each file, returns all subclasses
- `Eval.find(name)` — matches by underscored class name (e.g., `ParseItineraryEmailBasicEval` → `:parse_itinerary_email_basic_eval`)
- `Eval.for_subject(name)` — returns all evals that declare `evaluates name`
- Instance helpers: `run_subject`, `record_case_result`, `current_subject`, `current_case`
- `run_subject(subject, inputs: {})` — resolves subject via `Workbench.resolve`, constructs pipeline (using `Pipeline.lambda` for task subjects, `Pipeline.find` for pipeline subjects), merges inputs into context, calls `pipeline.run`, returns `pipeline.context`

**2. `evaluated_by` on Task and Pipeline** (`lib/workbench/task.rb`, `lib/workbench/pipeline.rb`)

- Class method `evaluated_by(name)` — stores names in `@eval_names` array (repeatable)
- Class reader `eval_names` — returns the array

**3. `Workbench::Dataset`** (`lib/workbench/dataset.rb`)

- `Dataset.find(name)` — looks for `datasets/<name>.yml`; raises if not found
- `Dataset.new(yaml_path)` — loads and parses YAML
- Attributes from YAML: `name`, `path` (relative to `fixtures/`; defaults to `name`), `include`, `ignore`, `sort`
- `#cases` — discovers and returns `Array<EvalCase>` using PR 1 default rules (see below)
- Raises if zero cases discovered

**Default discovery rules (PR 1):**

After applying `include`/`ignore` filters and excluding hidden files and common OS junk (`.DS_Store`, `Thumbs.db`):

1. If the target contains only files → each file is a case
2. If the target contains directories → each non-empty directory is a case; sibling files at that level are ignored

Sort order defaults to ascending; configurable via `sort:`.

**4. `Workbench::EvalCase`** (`lib/workbench/eval_case.rb`)

- `id`, `group_name`, `root_path`, `files` — set by dataset during discovery
- `inputs` — empty array in PR 1 (populated by `case.inputs` hints in PR 2)
- `outputs` — empty array in PR 1 (populated by `case.outputs` hints in PR 2)

**5. `Workbench::EvalFile`** (`lib/workbench/eval_file.rb`)

- `name`, `path`, `relative_path`, `read`

**Tests:**

- `test/workbench/eval_test.rb` — DSL declarations, `find`, `for_subject`, `inherited` registry
- `test/workbench/dataset_test.rb` — YAML loading, default discovery (files-as-cases, dirs-as-cases), include/ignore filtering, zero-cases error; all filesystem tests use `Dir.mktmpdir`

---

### Phase 2: Eval Runner + `workbench eval run`

**6. `Workbench::EvalRunner`** (`lib/workbench/eval_runner.rb`)

- `EvalRunner.new(eval_class)` — holds the eval class
- `#run` — full lifecycle:
  1. Resolve dataset; discover cases
  2. Instantiate eval; call `setup` if defined
  3. For each declared subject:
     a. For each case (in discovery order): set `current_subject` and `current_case` on instance; call `instance.run`; catch and record any uncaught exceptions as case errors
  4. Call `teardown` if defined
  5. Aggregate per-subject metrics by declared type
  6. Compute per-subject `pass_rate` and `pass_count` from `passed:` booleans
  7. Return structured `EvalRunResult`
- `EvalRunResult` — value object holding run_id, timestamps, per-subject results, per-case results

**7. `workbench eval` subcommand group** (`lib/workbench/cli.rb`)

- Introduce `Workbench::EvalCLI < Thor` registered as `subcommand "eval", EvalCLI` in `Workbench::CLI`
- `eval run --name` / `--subject` — validates exactly one provided; resolves eval(s); calls `EvalRunner#run` for each; prints summary

**Pretty-printed console output:**

```
Eval:     parse_itinerary_email_basic_eval
Subject:  parse_itinerary_email
Dataset:  golden_emails (10 cases)

  Pass rate:    8/10  (80.0%)
  exact_match:  0.750

  FAILED  case_04  (exact_match: 0.0)
  FAILED  case_09  (exact_match: 0.0)

Results written to eval_results/2026-04-23/parse_itinerary_email_basic_eval/
```

**Tests:**

- `test/workbench/eval_runner_test.rb` — lifecycle ordering (setup → cases → teardown), metric aggregation by type, pass_rate computation, error capture; pipeline execution stubbed to avoid filesystem dependency

---

### Phase 3: Result Artifacts

**8. `Workbench::EvalResultWriter`** (`lib/workbench/eval_result_writer.rb`)

- `EvalResultWriter.new(result, output_dir)` — accepts `EvalRunResult`
- `#write` — writes `summary.txt` and `run.json` to `output_dir`
- Output path: `eval_results/YYYY-MM-DD/<eval_name>/`; if path already exists, appends `_2`, `_3`, etc.

**`run.json` structure (normalized for future SQLite ingestion):**

```json
{
  "eval": "parse_itinerary_email_basic_eval",
  "run_id": "a1b2c3d4e5f6",
  "started_at": "2026-04-23T10:00:00Z",
  "finished_at": "2026-04-23T10:05:30Z",
  "dataset": "golden_emails",
  "subjects": [
    {
      "subject_name": "parse_itinerary_email",
      "subject_type": "pipeline",
      "case_count": 10,
      "pass_count": 8,
      "fail_count": 2,
      "error_count": 0,
      "pass_rate": 0.8,
      "metrics": {
        "exact_match": { "type": "average", "value": 0.75 }
      },
      "cases": [
        {
          "case_id": "case_01",
          "group_name": null,
          "passed": true,
          "error": null,
          "duration_ms": 1230,
          "metrics": { "exact_match": 1.0 },
          "outputs": {}
        }
      ]
    }
  ]
}
```

**`summary.txt`** — fixed-width plain text; same information as console output, formatted for reading in a terminal or diffing in git.

**Tests:**

- `test/workbench/eval_result_writer_test.rb` — file creation, correct paths, JSON structure, collision-avoidance suffix

---

### Phase 4: Advanced Dataset Discovery

**9. Extend `Workbench::Dataset`** (`lib/workbench/dataset.rb`)

**`directory: case` mode:**
- Immediate child directories of `path` are cases; sibling files ignored
- Empty directories skipped
- All nested content beneath a case directory is case payload (no sub-case creation)

**`directory: group` mode:**
- Immediate child directories are groups; files directly under `path` ignored
- Within each group, default discovery rules apply
- Files directly under a group directory are excluded from cases (surfaced as warnings in `dataset inspect`)

**`case.inputs` / `case.outputs` hints:**
- Glob patterns applied to files already discovered within a case
- Matched files populate `EvalCase#inputs` and `EvalCase#outputs`
- Unmatched files remain available via `EvalCase#files`

**`group.include` / `group.ignore` and `case.include` / `case.ignore`:**
- Applied during discovery within group and case scope respectively
- Applied after top-level `include`/`ignore` filtering

**YAML shape (full):**

```yaml
name: invoices
path: invoices
include:
  - "**/*"
ignore:
  - "*.rb"
sort: asc
directory: group

group:
  ignore:
    - "*.md"

case:
  ignore:
    - ".DS_Store"
  inputs:
    - "input/**"
  outputs:
    - "expected/**"
```

**Tests:**

- Extend `test/workbench/dataset_test.rb` — `directory: case`, `directory: group`, hints, nested filters, empty-folder skipping; all against `Dir.mktmpdir`

---

### Phase 5: `workbench eval dataset inspect`

**10. Add `dataset inspect` command** (`lib/workbench/cli.rb`)

- `Workbench::EvalDatasetCLI < Thor` registered as `subcommand "dataset", EvalDatasetCLI` inside `EvalCLI`
- `dataset inspect NAME` — resolves dataset as runtime would; prints groups, cases, file membership; surfaces warnings

Example output:

```
Dataset:  golden_emails
Path:     fixtures/golden_emails
Mode:     default (directories as cases)
Cases:    3

  case_01/
    email.txt       → input
    expected.json   → output

  case_02/
    email.txt       → input
    expected.json   → output

  case_03/
    email.txt       → input
    expected.json   → output
```

---

### Phase 6: CLI Developer Ergonomics

**11. `workbench eval create NAME --for SUBJECT[,SUBJECT]`**

- Creates `evals/<name>_eval.rb` with scaffolded class inheriting `Workbench::Eval`
- Creates `datasets/<name>.yml` stub (name field populated)
- Patches each subject file to add `evaluated_by :<name>_eval` if not already present
- Adds `evaluates :subject` declaration for each subject in the eval scaffold

**12. `workbench eval link NAME --for SUBJECT[,SUBJECT]`**

- Patches subject files to add `evaluated_by` if not already present
- Patches eval file to add `evaluates` if not already present
- Does not overwrite other file content

**13. `workbench eval check`**

- Runs all integrity checks; exits non-zero if any issues found (safe for CI)
- Reports `[missing-eval]`, `[missing-subject]`, `[orphaned-eval]`, `[broken-dataset]`
- Does not modify files

---

## Design Decisions

1. **`run` called per (subject, case) pair** — mirrors `Task#run`; runner sets `current_subject` and `current_case` on the eval instance before each call. Eval authors should not store per-case state in instance variables; use `record_case_result` instead.

2. **`pass_rate` is a built-in statistic, separate from named metrics** — automatically computed from per-case `passed:` booleans; always reported in results. Named metrics declared with `metric` are separate and aggregate by type. `passed:` is optional in `record_case_result`.

3. **Metric aggregation is type-driven** — the metric type (`average`, `sum`, etc.) determines how per-case values are combined. Eval authors provide per-case values; the runner performs aggregation. Custom aggregation can be added in a future phase.

4. **`EvalRunner` separate from `Eval`** — same rationale as `InputValidator` vs `Server`; orchestration logic is independently testable and keeps the `Eval` base class focused on the eval author's API.

5. **Dynamic eval loading via glob** — `Eval.all` globs `evals/**/*.rb` and requires each file; `inherited` hook tracks subclasses. Mirrors how tasks are loaded. No index file required.

6. **`run_subject` returns full pipeline context** — not just final task outputs. Gives eval authors access to intermediate task outputs, which is valuable for debugging and multi-step pipelines.

7. **Task subjects wrap in `Pipeline.lambda`** — consistent with how the server handles task endpoints. Task subjects always run inside a pipeline execution environment.

8. **Setup/teardown once per eval run** — not per subject or per case. For per-subject or per-case setup, eval authors can add logic at the top of `run` using `current_subject` / `current_case`. Per-subject setup may become a formal hook in a future phase.

9. **Dataset paths resolve only from `fixtures/`** — enforced in `Dataset`. Absolute paths and project-root-relative paths are rejected.

10. **`eval_results/` collision handling** — if `eval_results/YYYY-MM-DD/<eval_name>/` exists, append `_2`, `_3`, etc. Keeps results browsable by date and avoids overwriting prior runs.

11. **`eval check` is read-only** — does not modify files; safe to run in CI. `eval create` and `eval link` are the write path.

12. **`workbench eval` as Thor subcommand group** — `EvalCLI < Thor` registered via `subcommand "eval", EvalCLI` in the top-level `CLI` class. `dataset` is a further nested subcommand via `EvalDatasetCLI`.

---

## Dependencies

No new gem dependencies. All new functionality uses Ruby stdlib and existing workbench dependencies (`thor`, `activesupport`).

---

## File Changes Summary

| File | Change |
|------|--------|
| `lib/workbench/eval.rb` | New — `Eval` base class, DSL, instance helpers, registry |
| `lib/workbench/eval_runner.rb` | New — orchestrates eval lifecycle, metric aggregation |
| `lib/workbench/eval_result_writer.rb` | New — writes `summary.txt` and `run.json` |
| `lib/workbench/dataset.rb` | New — `Dataset` YAML loader and case discovery |
| `lib/workbench/eval_case.rb` | New — normalized case object |
| `lib/workbench/eval_file.rb` | New — normalized file object |
| `lib/workbench/task.rb` | Add `evaluated_by` class DSL |
| `lib/workbench/pipeline.rb` | Add `evaluated_by` class DSL |
| `lib/workbench/cli.rb` | Add `EvalCLI` subcommand group; `EvalDatasetCLI` nested group |
| `lib/workbench.rb` | Require new files |
| `test/workbench/eval_test.rb` | New |
| `test/workbench/eval_runner_test.rb` | New |
| `test/workbench/dataset_test.rb` | New |
| `test/workbench/eval_result_writer_test.rb` | New |

---

## Success Criteria

### PR 1: Core Runtime

- [ ] An eval class can declare `evaluates`, `dataset`, and `metric` at the class level
- [ ] A task or pipeline can declare `evaluated_by` to attach one or more evals
- [ ] `Eval.find(:name)` resolves an eval class by underscored name
- [ ] `Eval.for_subject(:name)` returns all evals with a matching `evaluates` declaration
- [ ] `Dataset.find(:name)` loads a YAML file from `datasets/`
- [ ] Dataset discovers flat files as cases and directories as cases using default rules
- [ ] Dataset raises an error when zero cases are discovered
- [ ] `workbench eval run --name <eval_name>` runs the eval end-to-end and prints a summary
- [ ] `workbench eval run --subject <subject_name>` runs all evals attached to the subject
- [ ] `run_subject` returns the pipeline's full context hash
- [ ] `record_case_result` with `passed: true/false` contributes to `pass_rate` statistic
- [ ] Named metrics are aggregated by their declared type across cases
- [ ] `setup` and `teardown` are called once per eval run if defined
- [ ] `eval_results/YYYY-MM-DD/<eval_name>/summary.txt` is written after each run
- [ ] `eval_results/YYYY-MM-DD/<eval_name>/run.json` is written with normalized structure
- [ ] Repeated runs on the same day produce `_2`, `_3`... suffixed directories

### PR 2: Full Dataset Discovery + Inspect

- [ ] `directory: case` treats immediate child directories as cases; sibling files ignored
- [ ] `directory: group` treats immediate child directories as groups; default discovery applied within each
- [ ] `case.inputs` / `case.outputs` hints populate `EvalCase#inputs` and `EvalCase#outputs`
- [ ] `group.include` / `group.ignore` filter files within group scope
- [ ] `case.include` / `case.ignore` filter files within case scope
- [ ] Empty directories are skipped as cases in all discovery modes
- [ ] Hidden files and common OS junk excluded by default
- [ ] `workbench eval dataset inspect <name>` prints groups, cases, and file membership as the runtime would resolve them
- [ ] `dataset inspect` surfaces warnings for files directly under group directories

### PR 3: CLI Ergonomics

- [ ] `workbench eval create <name> --for <subject>` creates eval file, dataset stub, and patches subject
- [ ] `workbench eval create` with multiple `--for` subjects patches all of them
- [ ] `workbench eval link <name> --for <subject>` patches existing eval and subject files
- [ ] `workbench eval check` reports `[missing-eval]` for unresolvable `evaluated_by` references
- [ ] `workbench eval check` reports `[missing-subject]` for unresolvable `evaluates` references
- [ ] `workbench eval check` reports `[orphaned-eval]` for eval files with no linked subject
- [ ] `workbench eval check` reports `[broken-dataset]` for missing or zero-case datasets
- [ ] `workbench eval check` exits non-zero when any issue is found
- [ ] `workbench eval check` exits zero when no issues are found (suitable for CI)
