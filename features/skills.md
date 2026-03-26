# Feature: Export Tasks to Claude Code Skills

## Overview

This feature adds a CLI command to export Workbench tasks as Claude Code skills. Each task's metadata (inputs, outputs, description) is transformed into a properly structured `SKILL.md` file that Claude can discover and invoke.

## CLI Interface

```bash
workbench export-skill <task_name> [options]
```

### Options

| Flag | Description | Default |
|------|-------------|---------|
| `--output-dir`, `-o` | Target directory for skill output | `.claude/skills/` |
| `--name`, `-n` | Override skill name (slug) | Task name underscored |
| `--description`, `-d` | Override description | Task class description |
| `--user-invocable` | Allow user to invoke via `/` command | `true` |
| `--model-invocable` | Allow Claude to auto-invoke | `true` |
| `--dry-run` | Print output without writing files | `false` |

### Examples

```bash
# Export a single task
workbench export-skill my_task

# Export with custom output location
workbench export-skill my_task -o ./my-project/.claude/skills/

# Export with custom name
workbench export-skill my_task --name "analyze-code"

# Preview without writing
workbench export-skill my_task --dry-run
```

## Task Metadata Extraction

The exporter will read task metadata from the existing DSL:

```ruby
class MyTask < Workbench::Task
  description "Analyzes code for common issues"

  input :file_path, type: :string, required: true, description: "Path to analyze"
  input :format, type: :string, default: "json", description: "Output format"

  output :issues, type: :array, export: true

  def run
    # ...
  end
end
```

### Required Task DSL Extension

Add a `description` class method to `Workbench::Task`:

```ruby
class Workbench::Task
  class << self
    def description(text = nil)
      if text
        @description = text
      else
        @description
      end
    end
  end
end
```

## Generated Skill Structure

### Task Export

For a task named `analyze_code`, generate:

```
.claude/skills/analyze-code/
└── SKILL.md
```

### SKILL.md Format

```yaml
---
name: analyze-code
description: Analyzes code for common issues. Use when the user wants to find problems in their code.
argument-hint: [file_path] [format?]
---

Run the analyze-code task from the Workbench framework.

## Inputs

- **file_path** (required): Path to analyze
- **format** (optional, default: "json"): Output format

## Invocation

To execute this task, run:

\`\`\`bash
bundle exec workbench start analyze_code --input file_path="$ARGUMENTS[0]" --input format="${ARGUMENTS[1]:-json}"
\`\`\`

## Expected Output

This task produces:
- **issues**: Array of identified issues
```

### Pipeline Export

For a pipeline named `code_review` with tasks `parse_code` -> `analyze_code` -> `format_report`:

```
.claude/skills/code-review/
└── SKILL.md
```

#### SKILL.md Format (Pipeline)

```yaml
---
name: code-review
description: Runs the full code review pipeline: parses code, analyzes for issues, and formats a report.
argument-hint: [file_path] [output_format?]
---

Run the code-review pipeline from the Workbench framework.

## Pipeline Tasks

1. **parse_code** - Parses the source file into an AST
2. **analyze_code** - Analyzes AST for common issues
3. **format_report** - Formats findings into requested output format

## Inputs

- **file_path** (required): Path to the file to review
- **output_format** (optional, default: "markdown"): Report format (markdown, json, html)

## Invocation

To execute this pipeline, run:

\`\`\`bash
bundle exec workbench start code_review --input file_path="$ARGUMENTS[0]" --input output_format="${ARGUMENTS[1]:-markdown}"
\`\`\`

## Expected Output

This pipeline produces:
- **report**: Formatted code review report (from format_report task)
```

## Implementation Plan

### Phase 1a: Task Export

1. **Add `description` DSL to Task** (`lib/workbench/task.rb`)
   - Class-level accessor for task description
   - Consider making it a required field for exportable tasks

2. **Create TaskSkillExporter class** (`lib/workbench/skill_exporter.rb`)
   - `initialize(task_class, options = {})`
   - `#metadata` - Extract task inputs/outputs/description
   - `#to_skill_md` - Generate SKILL.md content
   - `#export!` - Write to filesystem

3. **Add CLI command** (`lib/workbench/cli.rb`)
   - Register `export_skill` Thor command
   - Parse options and delegate to appropriate exporter

### Phase 1b: Pipeline Export

4. **Create PipelineSkillExporter class** (`lib/workbench/skill_exporter.rb`)
   - Faithfully represent the pipeline's full task sequence
   - Aggregate inputs from first task(s) that require external input
   - Aggregate outputs from tasks with `export: true`
   - Generate single SKILL.md that invokes the pipeline

5. **Pipeline skill structure**:
   - Document all tasks in sequence
   - Show data flow between tasks
   - Single CLI invocation: `workbench start <pipeline_name> --input ...`

### Phase 1c: Batch Export

6. **Add `--all` flag** to export command
   - `workbench export-skill --all --type tasks` - Export all tasks
   - `workbench export-skill --all --type pipelines` - Export all pipelines
   - `workbench export-skill --all` - Export everything

7. **Validation** - Warn if task/pipeline lacks description or inputs

### Phase 2: Advanced Integration

8. **Bidirectional sync** - Detect manual SKILL.md edits, preserve customizations
9. **Hooks integration** - Auto-regenerate skills when tasks change
10. **Version tracking** - Include task/pipeline version in skill metadata

## Design Decisions

1. **CLI invocation over prompt embedding**
   - Skills invoke tasks/pipelines via CLI (`bundle exec workbench start ...`)
   - Rationale: Tasks may modify prompts using their own logic; embedding would lose this flexibility

2. **Tasks vs Pipelines as separate export targets**
   - Individual task export: Handles that task's inputs/outputs only
   - Pipeline export: Faithfully represents the full combination of tasks
   - Each generates its own SKILL.md with appropriate invocation

## Open Questions

1. **Should exported skills fork context?**
   - Tasks that modify state might benefit from `context: fork`
   - Could be configurable per-task

2. **Input type mapping**
   - How to map Ruby types to skill argument hints?
   - Suggestion: `:string` -> plain, `:boolean` -> `[--flag]`, `:array` -> `[item...]`

3. **Pipeline input aggregation**
   - When a pipeline has multiple tasks, which inputs surface to the skill?
   - Proposal: Only inputs from tasks that don't receive values from prior task outputs

## Dependencies

- Existing: `thor`, `activesupport`
- New: None required

## File Changes Summary

| File | Change |
|------|--------|
| `lib/workbench/task.rb` | Add `description` class method |
| `lib/workbench/skill_exporter.rb` | New file - TaskSkillExporter and PipelineSkillExporter |
| `lib/workbench/cli.rb` | Add `export_skill` command with task/pipeline detection |
| `lib/workbench.rb` | Require skill_exporter |

## Success Criteria

### Phase 1a: Task Export
- [ ] `workbench export-skill my_task` generates valid SKILL.md
- [ ] Exported task skills are discoverable by Claude Code
- [ ] Generated invocation commands execute correctly
- [ ] Input/output documentation is accurate
- [ ] Dry-run mode works without filesystem changes

### Phase 1b: Pipeline Export
- [ ] `workbench export-skill my_pipeline` generates valid SKILL.md
- [ ] Pipeline skill documents all tasks in sequence
- [ ] Inputs are correctly aggregated from pipeline entry points
- [ ] Outputs reflect exported values from final tasks

### Phase 1c: Batch Export
- [ ] `workbench export-skill --all` exports all tasks and pipelines
- [ ] `--type` flag correctly filters to tasks or pipelines only
- [ ] Conflicts/overwrites are handled gracefully
