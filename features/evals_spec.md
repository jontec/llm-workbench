# Evals for LLM Workbench

Draft spec and README-style guidance for adding **Evals** as a first-class feature to LLM Workbench.

---

## 1. Goals

Add a first-class evaluation framework to LLM Workbench so developers can:

- attach evals directly to Tasks and Pipelines
- define evals as reusable, version-controlled code artifacts
- run evals from the CLI against a single eval or all evals attached to a subject
- use curated datasets for evaluation inputs and expected outputs
- support both deterministic assertions and LLM-powered judging
- persist evaluation results in a machine-readable format and a human-readable summary
- eventually evolve toward a local SQLite-backed evaluation store and UI

This should feel native to Workbench’s existing conventions:

- declarative definitions
- filesystem-based project structure
- Ruby classes for logic
- YAML/config-driven composition where helpful
- CLI-first ergonomics

---

## 2. Core Concepts

### Subject
A **subject** is the thing being evaluated.

Supported subject types:

- **Task**
- **Pipeline**

A subject is evaluable because it has:

- defined inputs, or inputs that can be inferred
- defined outputs, or outputs that can be inferred

A subject may have empty inputs in some edge cases, but it should always produce at least one meaningful output to be evaluated.

### Eval
An **Eval** is a definition that runs a subject against one or more cases and scores the result.

An eval:

- identifies the subject it evaluates
- defines or references evaluation cases
- invokes the subject with known inputs
- inspects the produced outputs
- computes one or more metrics
- emits detailed results and summary stats

An eval may use:

- simple assertions
- custom Ruby logic
- expected output matching
- LLM-as-a-judge behavior
- weighted scoring across multiple metrics

### Dataset
A **Dataset** is a first-class collection of evaluation data used by one or more evals.

Datasets may include:

- input-only test cases
- input + expected output pairs
- metadata for filtering, tagging, grouping, or weighting
- fixture references or external artifacts

Datasets are especially valuable because Workbench already models chained inputs and outputs across tasks. This makes it practical to:

- generate candidate expected outputs from earlier runs
- curate datasets over time
- record expensive LLM-generated fixtures
- use tools like VCR to stabilize and replay evaluation dependencies

### Metric
A **Metric** is a named measurement produced by an eval.

Examples:

- pass rate
- exact match
- precision
- recall
- rubric score
- latency
- cost

An eval can produce multiple metrics in one run.

### Eval Run
An **Eval Run** is a single execution of an eval against a dataset or set of cases.

An eval run should produce:

- summary statistics
- per-case detail
- configuration metadata
- timestamps and identifiers
- machine-readable output for later aggregation

---

## 3. High-Level Design Principles

### Declarative subject attachment
Subjects should be able to declare which evals apply to them.

Proposed API:

```ruby
class ParseItineraryEmail < Workbench::Task
  evaluated_by :parse_itinerary_email_basic
  evaluated_by :parse_itinerary_email_precision
end
```

Equivalent support should exist for Pipelines.

### Declarative eval-to-subject mapping
An eval should also be able to declare the subject it evaluates.

Proposed API:

```ruby
class ParseItineraryEmailBasicEval < Workbench::Eval
  evaluates :parse_itinerary_email
end
```

This creates a bidirectional association:

- the subject can expose its attached evals
- the eval can resolve and validate its subject

This also helps scaffolding and discovery tooling.

### Dataset-first design
Curated datasets should be treated as a first-class primitive rather than an afterthought.

This is important because, in practice, high-quality evals depend more on stable and curated evaluation data than on scoring code alone.

### Flexible evaluation logic
The framework should support a spectrum of evaluation styles:

- deterministic checks
- partial scoring
- multi-metric scoring
- custom Ruby logic
- LLM judge calls
- hybrid approaches

### Stable, inspectable artifacts
Eval definitions, datasets, and results should be easy to inspect in version control and locally on disk.

### Evolvable persistence
Initial file-based outputs should be structured so they can later be ingested into SQLite without redesigning the conceptual model.

---

## 4. Proposed New Primitive: Eval

Introduce a new primitive:

- **Eval**: a Ruby class responsible for running one evaluation definition against one or more subjects

This should be a Ruby-class-based concept in all cases, not a purely declarative file format.

Possible example:

```ruby
require 'workbench'

class ParseItineraryEmailBasicEval < Workbench::Eval
  evaluates :parse_itinerary_email
  dataset :golden_emails

  metric :pass_rate
  metric :exact_match

  def run_case(test_case, subject_name:)
    result = run_subject(subject_name, inputs: test_case.inputs)

    assert_equal test_case.expected_outputs[:booking_count], result[:booking_count]

    exact = result[:bookings] == test_case.expected_outputs[:bookings]

    record_case_result(
      subject_name: subject_name,
      passed: exact,
      metrics: {
        exact_match: exact ? 1.0 : 0.0
      },
      outputs: result
    )
  end
end
```

This API is illustrative only. The real implementation should match Workbench’s existing naming and runtime conventions.

An eval should be able to evaluate more than one subject when explicitly linked to multiple subjects.

## 5. Proposed Supporting Primitive: Dataset

Introduce a supporting primitive:

- **Dataset**: a structured collection of eval cases, defined initially by YAML

Datasets should be first-class, but for the initial version their canonical representation should be a YAML file spec.

The purpose of the dataset YAML is not to fully encode evaluation semantics. Its primary job is to describe:

- which files under `fixtures/` should be exposed
- how those files should be grouped into cases
- optionally, how those cases should be grouped for reporting
- optionally, how discovered files should be surfaced as likely inputs or outputs

A dataset spec may be extremely small. In the simplest case, it can be just:

```yaml
name: golden_emails
```

In that case, Workbench should apply default discovery rules against `fixtures/golden_emails/`.

### Dataset path rules

Datasets should resolve files only from paths relative to `fixtures/`.

Examples:

```yaml
name: golden_emails
path: golden_emails
```

```yaml
name: invoice_cases
path: invoices/smoke
```

Paths should not be expressed as project-root-relative or absolute filesystem paths in the initial design.

### Default discovery behavior

After include/ignore filtering has been applied, the discovered structure should be interpreted using these defaults:

1. **List of files** → each file is a case
2. **List of folders with no subgroup structure** → each folder is a case
3. **Compound list of folders** → first level folders are groups, each nested folder is a case

Important clarifications:

- structure inference happens **after filtering**
- if the target directory contains folders, Workbench should default to using each folder as a case and ignore sibling files at that same level
- once a directory is identified as a case, all files and nested directories beneath it belong to that case and are exposed to the eval
- empty folders should be skipped as cases
- hidden files and common OS junk should be excluded by default, with the ability to override those defaults
- case discovery should use ascending sort order by default

### Suggested initial YAML fields

The initial dataset YAML should stay small and focus on discovery.

```yaml
name: golden_emails
path: golden_emails
include:
  - "**/*"
ignore:
  - "*.rb"
sort: asc
```

Suggested meanings:

- `name`: dataset name
- `path`: path relative to `fixtures/`
- `include`: glob patterns for paths to include
- `ignore`: glob patterns for paths to exclude
- `sort`: sort order for deterministic case discovery, defaulting to ascending

### Structural interpretation and overrides

Workbench should support clear defaults, but it should also allow explicit overrides for common exceptions.

For MVP, a compact and opinionated override should be supported via:

```yaml
directory: case
```

or:

```yaml
directory: group
```

These declarations apply only to the immediate child directories of `path`, after filtering.

#### `directory: case`

Meaning:

- interpret the immediate child directories of `path` as cases
- sibling files at that same level are ignored
- once a directory is identified as a case, all files and nested directories beneath it belong to that case
- empty directories are skipped as cases
- from the case root downward, default interpretations no longer create nested cases; nested content is simply case payload exposed to the eval

#### `directory: group`

Meaning:

- interpret the immediate child directories of `path` as groups
- files directly under `path` are ignored
- within each group, default dataset interpretations are applied from that point forward
- once a nested directory is identified as a case, all files and nested directories beneath it belong to that case
- empty directories are skipped as cases

This allows the top-level schema to stay small while preserving room for more detailed handling under future `group:` and `case:` sections.

### Future `group:` and `case:` configuration blocks

If further specificity is needed, it should live under separate `group:` or `case:` keys rather than expanding the meaning of the top-level structural mode.

This creates a clean extension point for:

- group-specific include/ignore filters
- case-specific include/ignore filters
- naming rules
- file role mapping such as likely inputs and outputs
- future reporting and metadata configuration

For MVP, `group:` and `case:` should already support `include` and `ignore`.

Illustrative shape:

```yaml
name: invoices
path: invoices
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

For grouped datasets, files directly under a group directory should be ignored by default. They may later be surfaced as warnings in inspection or check tooling, but they should not be treated as cases or group-level attachments in the MVP.

Common useful interpretations:

- files in a directory are cases
- directories in a directory are cases
- directories in a directory are groups, with nested items forming cases

Common exceptions worth supporting:

- a set of folders specifies the individual eval cases, even when those case folders contain subfolders
- a set of folders specifies groups, and each file within those folders is a separate case

### Inputs and outputs in datasets

There is a strong desire to identify not only gross files in a case, but likely inputs and outputs for that eval case.

For the MVP, this should be supported as an optional and lightweight hinting mechanism under `case:`.

Illustrative shape:

```yaml
case:
  inputs:
    - "input/**"
    - "*.pdf"
  outputs:
    - "expected/**"
    - "*.json"
```

Semantics:

- these are pattern hints, not strict schema enforcement
- they classify files already discovered within a case
- unmatched files remain available as general case payload
- eval code may use these hints or ignore them entirely

This preserves the separation between dataset discovery and eval interpretation while still supporting a useful, opinionated mapping for common cases.

### Normalized case model

Regardless of discovery mode, the eval should receive normalized case objects with stable structure.

A case should expose a small canonical API that eval authors can rely on, independent of how the dataset was discovered.

At minimum, a case should expose:

- `id`
- `group_name`
- `root_path`
- `files`
- `inputs`
- `outputs`

Illustrative case API:

```ruby
case.id
case.group_name
case.root_path
case.files
case.inputs
case.outputs
```

Files exposed through a case should also use a small normalized API.

At minimum, a file should expose:

- `relative_path`
- `path`
- `name`
- `read`

Illustrative file API:

```ruby
file.relative_path
file.path
file.name
file.read
```

This keeps dataset discovery separate from eval interpretation and prevents each eval from having to re-implement filesystem logic.

### Validation expectations

Datasets should validate and fail loudly on clearly broken setups.

Expected behavior:

- zero discovered cases should be an error
- empty folders should be skipped rather than treated as cases
- hidden files and default junk files should be excluded by default
- discovery order should be deterministic

### Warning behavior and developer tooling

`workbench eval dataset inspect` and `workbench eval check` should have different jobs.

#### `workbench eval dataset inspect`
- resolve a dataset exactly as the runtime would
- show discovered groups, cases, and file membership
- help debug include/ignore filters and structural interpretation
- surface warnings for ignored files that appear directly under group directories
- serve as a developer aid for discovery-driven datasets
- be included in the MVP because it materially improves dataset debugging and testability

### 6.8 Pretty-printed output
Console output should be easy to scan.

Desired output should include:

- eval name
- subject name
- dataset name and case count
- top-level pass/fail or score summary
- named metrics
- failures and error counts
- path to written result artifacts

### 6.9 Future database compatibility
The file output model should anticipate a future SQLite-backed store.

Requirements:

- stable run IDs
- normalized per-case records
- metric records that can be flattened into tables
- compatibility with later local UI or analytics tools

---

## 7. Suggested Project Structure

This is one possible structure.

```text
project_root/
  evals/
    parse_itinerary_email_basic_eval.rb
  datasets/
    golden_emails.yml
  fixtures/
    golden_emails/
      emails/
      expected/
  eval_results/
    2026-04-14/
      parse_itinerary_email_basic_eval/
        summary.txt
        run.json
```

Alternative conventions are possible, but the key idea is to give evals and datasets obvious homes analogous to tasks, pipelines, prompts, and schemas.

For the initial version, dataset YAML should be the canonical dataset entrypoint, and dataset paths should resolve only within `fixtures/`.

## 8. Runtime Model

At a high level, an eval run would look like this:

1. Resolve the eval definition.
2. Resolve the subject.
3. Resolve the dataset or inline cases.
4. Execute the subject once per case.
5. Capture outputs, errors, timings, and metadata.
6. Score each case.
7. Aggregate metrics across all cases.
8. Write result artifacts.
9. Pretty-print a summary in the CLI.

Potential future enhancements:

- case filtering by tag
- sampling
- retries
- concurrency
- snapshot comparison between runs
- regression detection
- baseline vs candidate comparison
- recording subject runs into dataset fixtures for later curation

### Recording workflows and VCR-oriented helpers

A useful future helper would be a recording-oriented workflow such as:

```bash
workbench start <task_or_pipeline> --record-to-dataset <dataset_name>
```

Or:

```bash
workbench eval record --subject <subject_name> --dataset <dataset_name>
```

Conceptually, this would help with dataset building rather than scoring. For example:

- run a task or pipeline against live inputs
- capture the subject inputs and outputs
- optionally capture fixture references
- append or stage a candidate case into a dataset YAML file and fixture directory
- optionally preserve related HTTP or LLM interactions using VCR or a Workbench wrapper around VCR

This should likely be framed as dataset curation support rather than as core eval execution.

For the MVP, VCR integration can be a helper-oriented roadmap item rather than a hard dependency of the core eval runner.

## 9. README-Style Usage Guidance

## Evals

LLM Workbench supports first-class evals for Tasks and Pipelines.

An eval is a reusable definition that runs a subject against curated cases, scores the outputs, and writes both console-friendly and machine-readable results.

### Why use evals?

Evals help you:

- catch regressions before shipping prompt or code changes
- compare alternative prompts, models, and task implementations
- build stable benchmark datasets over time
- measure multiple dimensions of quality such as pass rate, precision, recall, or rubric score
- preserve expensive or hard-to-reproduce fixtures for repeatable testing

### Attaching evals to a subject

A Task or Pipeline can declare one or more attached evals:

```ruby
class ParseItineraryEmail < Workbench::Task
  evaluated_by :parse_itinerary_email_basic
  evaluated_by :parse_itinerary_email_llm_judge
end
```

### Declaring the subject in the eval

Each eval declares the subject it evaluates:

```ruby
class ParseItineraryEmailBasicEval < Workbench::Eval
  evaluates :parse_itinerary_email
end
```

### Using datasets

Evals can reference curated datasets containing:

- test inputs
- expected outputs
- tags
- weights
- fixture files

This makes it easier to keep evaluation logic separate from evaluation data.

### Running evals

Run a specific eval:

```bash
workbench eval run --name parse_itinerary_email_basic
```

Run all evals attached to a subject:

```bash
workbench eval run --subject parse_itinerary_email
```

When running by subject, Workbench should use the subject’s declared `evaluated_by` list as the source of truth.

### Working with datasets

Datasets are defined by YAML and use files under `fixtures/` as the source material for evaluation cases.

A dataset may be extremely small:

```yaml
name: golden_emails
```

In that case, Workbench should look for files under `fixtures/golden_emails/` and apply default discovery rules.

You can also be more explicit:

```yaml
name: invoices
path: invoices
ignore:
  - "*.rb"
sort: asc
directory: case
```

In this example:

- `path` is resolved relative to `fixtures/`
- `ignore` filters are applied before structure is inferred
- `directory: case` means each top-level directory under the dataset path is treated as a case
- all nested files beneath each case directory are exposed to the eval as case payload

For grouped datasets:

```yaml
name: invoices_by_difficulty
path: invoices_by_difficulty
directory: group
```

In this example:

- each top-level directory under the dataset path is treated as a group
- default dataset interpretations are then applied within each group
- files directly under the dataset root are ignored

This allows datasets to remain discovery-driven while giving evals normalized case objects to work with.

### Creating a new eval

Scaffold a new eval:

```bash
workbench eval create parse_itinerary_email_basic --for parse_itinerary_email
```

Or scaffold and link it to multiple subjects:

```bash
workbench eval create shared_contract_eval --for parse_itinerary_email,parse_booking_email
```

This command should:

- create the eval file
- edit the subject file or files to add `evaluated_by`
- add the `evaluates` declaration
- scaffold a starter dataset YAML file or fixtures directory when appropriate

### Linking an existing eval

Attach an existing eval to one or more subjects:

```bash
workbench eval link shared_contract_eval --for parse_itinerary_email,parse_booking_email
```

### Checking eval integrity

Validate eval linkage and project consistency:

```bash
workbench eval check
```

This command should detect things like missing references, orphaned declarations, or mismatches between subject and eval definitions.

### Result artifacts

Each eval run writes:

- a human-readable plain-text summary file formatted for fixed-width viewing
- a JSON file containing full run details

These result files are designed for local inspection today and future SQLite-backed reporting tomorrow.

### Deterministic and LLM-based judging

Evals can use simple assertions for deterministic checks or call an LLM to judge outputs against a rubric or expected result.

Pass/fail semantics do not need to be globally imposed by the framework. Instead, the framework should assemble and persist results while allowing the eval itself to define how results are interpreted.

For non-deterministic LLM-powered workflows, recorded fixtures and tools like VCR can help stabilize external calls and preserve curated benchmarks over time.

### Building datasets from live runs

A future helper workflow may support recording live subject runs into dataset fixtures. This could make it easier to:

- bootstrap a new dataset from real examples
- capture subject inputs and outputs together
- preserve artifacts for later curation
- combine dataset creation with recorded HTTP or LLM interactions

### Best practices

- keep datasets under version control
- start with a small smoke dataset, then grow toward a golden set
- separate scoring logic from fixture data
- record unstable or expensive dependencies where possible
- track multiple metrics instead of collapsing everything into one number too early
- preserve per-case detail so failures are debuggable

---

## 10. Remaining Future Considerations

Most of the major product-shape decisions for the MVP are now settled. The remaining items are primarily future-looking considerations rather than blockers for the initial implementation.

### A. Dataset evolution
- Should `Dataset` eventually become a Ruby wrapper around YAML, or remain YAML-first with helper loaders only?
- How should Workbench eventually support multi-file cases represented by filename conventions rather than directory boundaries?
- If group-level attachments are ever supported, how should they coexist with the current rule that files directly under a group directory are ignored?

### B. Results evolution
- The proposed slightly normalized `run.json` should be treated as the default contract for initial persistence and future SQLite ingestion.
- Later iterations may decide whether to formalize this into a stricter schema versioning story.

### C. Recording and curation
- Should dataset recording live under `workbench start`, under `workbench eval`, or both?
- Should recording append directly into dataset YAML, stage candidate cases separately, or write reviewable drafts first?
- How tightly should Workbench wrap VCR versus simply providing helper conventions?

### D. Post-MVP ergonomics
- Should future versions add richer per-case metadata sidecars?
- Should future versions add more advanced role mapping beyond `case.inputs` / `case.outputs`?
- Should future versions add baseline comparison and regression gating helpers?

## 11. Suggested Initial Milestone

A pragmatic first milestone could be:

1. Add `Workbench::Eval` as a Ruby-class primitive.
2. Add `evaluated_by` and repeatable `evaluates` declarations.
3. Support one-to-many linking between an eval and explicitly chosen subjects.
4. Support YAML-backed datasets with fixture directory conventions.
5. Support default discovery plus `directory: case` and `directory: group` overrides.
6. Support optional `case.inputs` and `case.outputs` pattern hints.
7. Support `group.include` / `group.ignore` and `case.include` / `case.ignore` in MVP.
8. Support deterministic scoring and custom Ruby scoring.
9. Add `workbench eval create`, `workbench eval link`, `workbench eval check`, `workbench eval run`, and early `workbench eval dataset inspect` support.
10. Always scaffold a dataset YAML stub during eval creation.
11. Write fixed-width-friendly `summary.txt` and slightly normalized `run.json`.
12. Pretty-print results in the CLI.

That would create a strong foundation without forcing the full SQLite/UI design up front.

## 12. Suggested Next Iteration After MVP

After the MVP, likely next steps would be:

- first-class dataset helpers
- LLM judge helpers
- VCR integration helpers for recording and replay
- thresholds and CI gating
- run comparison and diffing
- SQLite-backed result store
- local eval browser or dashboard
- export adapters for external observability tools

