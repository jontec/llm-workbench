# Feature: Deploy Tasks and Pipelines as API Endpoints

## Overview

This feature enables pipelines and tasks to be executed as API endpoints, supported principally by new `deploy` and `serve` commands.

`deploy` registers a task or pipeline as an HTTP endpoint (described within corresponding YAML files in `endpoints/`) and `serve` launches a Roda-based HTTP server that exposes all deployed endpoints. Callers can trigger a pipeline by POSTing to its endpoint with JSON inputs and detailed settings can be written within the endpoint YAML files.

Utilities for reviewing endpoints (`endpoints`) and removing endpoints (`undeploy`) are also included. The `endpoints` command can also help detect (`--check`) and fix (`--cleanup`) issues with endpoint definitions.

This feature is designed with forward compatibility in mind: future work will add per-project and per-pipeline configuration (including database setup/teardown), and deployed pipelines should accommodate those config options without breaking changes.

## Build Plan

Development happens on a single `feature/api-endpoints` branch. Three PRs target `main` in sequence — each builds on the last and is independently mergeable.

| PR | Phases | Description |
|----|--------|-------------|
| **PR 1** | 1, 2, 2b, 3, 4 | Core feature: endpoint files, CLI commands, integrity checks, Roda server, input validation. Mergeable when a user can `deploy` a pipeline, `serve` it, and call it over HTTP. |
| **PR 2** | 5 | Async execution: `--async` flag, background pipeline runs, flat-file status persistence, polling route. |
| **PR 3** | 6 | OpenAPI spec: auto-generation on `deploy`/`undeploy`/`serve`, drift detection in `endpoints --check`, Swagger UI at `/docs`. |

**Working conventions:**
- Commit at logical stopping points within each phase; prefix in-progress commits with `WIP:`
- Check off success criteria in this file as each is verified
- Each PR description references the relevant phase(s) of this plan

## CLI Interface

```bash
workbench deploy <task_or_pipeline_name> [options]
workbench undeploy <task_or_pipeline_name>
workbench endpoints [--check] [--cleanup]      # list, verify, or repair endpoints
workbench serve [options]                      # start the HTTP server
```

### `deploy` Options

| Flag | Description | Default |
|------|-------------|---------|
| `--path`, `-p` | HTTP path for the endpoint | `/<name>` (dasherized) |
| `--method`, `-m` | HTTP verb (may be specified multiple times) | `POST` |
| `--async` | Return immediately, run pipeline in background | `false` |
| `--dry-run` | Preview endpoint file without writing | `false` |

### `serve` Options

| Flag | Description | Default |
|------|-------------|---------|
| `--port` | Port to bind | `9292` |
| `--host` | Host to bind | `0.0.0.0` |
| `--config` | Path to workbench config file | `workbench.yml` |

With a `server.base_path` set in `workbench.yml`, all endpoint routes are prefixed automatically. For example, `base_path: /api/v1` causes `endpoints/code_review.yml` to be served at `/api/v1/code-review`. The OpenAPI spec and its UI are also served under the base path.

### `endpoints` Options

| Flag | Description |
|------|-------------|
| _(none)_ | List all active routes and their pipeline/task mappings |
| `--check` | Validate all endpoints; exit non-zero if issues found (safe for CI) |
| `--cleanup` | Describe issues and proposed fixes, prompt for confirmation before applying |

### Examples

```bash
# Deploy a pipeline (creates endpoints/code_review.yml)
workbench deploy code_review

# Deploy to a nested path (creates endpoints/tools/linter.yml)
workbench deploy run_linter --path /tools/linter

# Deploy a single task
workbench deploy analyze_code

# Preview without writing
workbench deploy code_review --dry-run

# Start the server
workbench serve --port 3000

# Remove an endpoint
workbench undeploy code_review

# List all endpoints
workbench endpoints

# Check endpoint integrity (usable in CI)
workbench endpoints --check

# Review and interactively fix endpoint issues
workbench endpoints --cleanup
```

## Endpoint Files

`deploy` writes one YAML file per endpoint into the `endpoints/` directory. The file's path relative to `endpoints/` encodes the HTTP route — no separate path field is needed. `serve` discovers all endpoints at startup via `Dir.glob("endpoints/**/*.yml")` and reconstructs routes from file locations.

This makes endpoints first-class project citizens: they are checked into version control, immediately discoverable, and produce clean diffs when added or changed.

```
endpoints/
├── code_review.yml          # → POST /code-review
└── tools/
    └── linter.yml           # → POST /tools/linter
```

Each file describes the HTTP methods for that route and which pipeline or task each method invokes:

```yaml
# endpoints/code_review.yml
methods:
  POST:
    pipeline: code_review    # "pipeline" or "task"
    async: false
    deployed_at: "2026-03-25T10:00:00Z"
```

A single endpoint can serve multiple methods if needed:

```yaml
# endpoints/tools/linter.yml
methods:
  POST:
    pipeline: run_linter
    async: false
    deployed_at: "2026-03-25T10:05:00Z"
  GET:
    pipeline: linter_status
    async: true
    deployed_at: "2026-03-25T10:05:00Z"
```

> **Note:** Path parameters (e.g. `/tools/linter/:id`) are not supported in Phase 1, as colons cannot appear in filenames. This constraint may be revisited in a future phase.

## HTTP API

### Request

Inputs are passed as a JSON body. The server maps JSON keys to pipeline/task input names. If `server.base_path` is set (e.g. `/api/v1`), all routes are prefixed accordingly.

```
POST /api/v1/code-review
Content-Type: application/json

{
  "file_path": "src/main.rb",
  "output_format": "markdown"
}
```

### Response (synchronous)

```json
{
  "status": "ok",
  "pipeline": "code_review",
  "outputs": {
    "report": "## Code Review\n..."
  }
}
```

### Response (async)

```json
{
  "status": "accepted",
  "pipeline": "code_review",
  "run_id": "a1b2c3d4"
}
```

### Error Response

```json
{
  "status": "error",
  "error": "Missing required input: file_path"
}
```

## Implementation Plan

### Phase 1: Endpoint Files

1. ✅ **Create `Workbench::Endpoint` class** (`lib/workbench/endpoint.rb`)
   - Represents a single endpoint file: its route path (derived from file path), and the method→pipeline/task mappings it contains
   - `Endpoint.all` — `Dir.glob("endpoints/**/*.yml")`, parse each file, derive route from relative path
   - `Endpoint.register!(pipeline_or_task_name, options)` — resolve file path from `--path`, write or merge endpoint file
   - `Endpoint.unregister!(pipeline_or_task_name)` — remove the method entry; delete file if no methods remain
   - Detect whether `name` resolves to a pipeline or a task at registration time

2. ✅ **File path → route path convention**
   - Strip `endpoints/` prefix, strip `.yml` extension, dasherize each path segment
   - `endpoints/code_review.yml` → `/code-review`
   - `endpoints/tools/linter.yml` → `/tools/linter`
   - Create intermediate directories as needed on first write

3. ✅ **Tests for `Workbench::Endpoint`** (`test/workbench/endpoint_test.rb`)
   - `file_to_route` and `route_to_file`: pure conversion cases — simple name, nested path, underscored segments
   - `register!`: verify file is written with correct structure; verify merging a second method into an existing file
   - `unregister!`: verify method entry removal; verify file deletion when last method is removed; verify empty parent directory cleanup
   - All filesystem tests run against a `Dir.mktmpdir` temporary directory, never the real `endpoints/` folder

### Phase 2: CLI Commands

3. ✅ **Add `Workbench.resolve` helper** (`lib/workbench.rb`)
   - Tries `Pipeline.find` first, then `Task.find`; raises `ArgumentError` with name included if neither resolves
   - Unit tests in `test/workbench/resolve_test.rb` using Minitest stubs

4. ✅ **Add `deploy` Thor command** (`lib/workbench/cli.rb`)
   - Resolve name to task or pipeline via `Workbench.resolve`
   - Derive target file path from `--path` (or default dasherized name)
   - Delegate to `Endpoint.register!` with merged options
   - Print confirmation (or dry-run preview) of the file that will be written and the route it encodes
   - After writing, regenerate `openapi.yml` as a side effect (Phase 6)

5. ✅ **Add `undeploy` Thor command** (`lib/workbench/cli.rb`)
   - Delegate to `Endpoint.unregister!`
   - After removing, regenerate `openapi.yml` as a side effect (Phase 6)

6. ✅ **Add `endpoints` Thor command** (`lib/workbench/cli.rb`)
   - _(no flags)_ Pretty-print all routes and their method→pipeline/task mappings from `Endpoint.all`
   - `--check` — run all integrity checks (see below) and report issues; exit non-zero if any found, making it safe for use in CI pipelines
   - `--cleanup` — run the same checks, print a dry-run summary of proposed fixes, prompt for confirmation, then apply

   **Integrity checks performed by `--check` and `--cleanup`:**
   - `[missing]` — a method entry references a pipeline or task that cannot be resolved
   - `[stale-spec]` — `openapi.yml` is out of sync with current endpoint files and task/pipeline definitions (detected by regenerating the spec in memory and diffing against the file on disk)
   - `[empty]` — an endpoint file exists but defines no methods
   - `[duplicate]` — two files resolve to the same route after dasherization

   **Cleanup actions (applied only after confirmation):**
   - Remove orphaned method entries from endpoint files
   - Delete endpoint files that are empty after pruning
   - Regenerate `openapi.yml` to match current state
   - Cleanup only prunes; re-pointing an endpoint to a renamed pipeline or task is the developer's responsibility

### Phase 3: Roda Server

6. **Create `Workbench::Server` class** (`lib/workbench/server.rb`)
   - Subclasses `Roda`
   - On startup, load `Endpoint.all` and register routes dynamically from file locations
   - Each route: parse JSON body → build input hash → find and run pipeline/task → serialize outputs to JSON

7. **Add `serve` Thor command** (`lib/workbench/cli.rb`)
   - Validate that `server.api_key` is set in `workbench.yml`; refuse to start if absent
   - Instantiate `Workbench::Server` and run via Rack handler (e.g. `Rack::Handler::WEBrick` or Puma)
   - Accept `--port` / `--host` options
   - All requests are authenticated via `Authorization: Bearer <key>` before reaching any route; unauthenticated requests receive 401

8. **Add `roda` dependency** (`llm-workbench.gemspec`)
   - `rack` is a transitive dependency of `roda` and need not be listed explicitly

### Phase 4: Input Validation

9. **Validate request inputs against task/pipeline input definitions**
   - Reuse existing `input_definitions` from `Task` subclasses
   - Return 422 with descriptive error JSON if required inputs are missing or wrong type

### Phase 5: Async Execution (stretch)

10. **Async mode**
    - Assign a `run_id` (SecureRandom.hex) per invocation
    - Run pipeline in a background thread; write status and outputs to `.workbench/runs/<run_id>.json` on completion
    - Add `GET [base_path]/status/:run_id` route to read and return the run file; 404 if not yet written, 200 with outputs once complete
    - Create `.workbench/runs/` on first async run if absent; add to `.gitignore`

### Phase 6: OpenAPI Spec

11. **Create `Workbench::OpenAPIGenerator` class** (`lib/workbench/openapi_generator.rb`)
    - `#generate` — build an OpenAPI 3.0 document from `Endpoint.all` and the task/pipeline input and output definitions
    - For each endpoint file: one OpenAPI path entry per HTTP method, with `requestBody` schema derived from `input_definitions` and `responses` schema derived from `output_definitions`
    - Include `info.title` from `project.name`, `info.version` from `server.base_path` (e.g. `v1`) if present, `servers` entry from host/port
    - `#generate!` — write spec to `openapi.yml` in the project root
    - `#stale?` — regenerate spec in memory, diff against `openapi.yml` on disk; return true if they differ (used by `endpoints --check`)

12. **Integrate spec regeneration into existing commands** — no standalone `openapi` command
    - `deploy` and `undeploy` call `OpenAPIGenerator#generate!` after modifying endpoint files
    - `serve` calls `OpenAPIGenerator#generate!` at startup so the served spec always reflects current definitions
    - `endpoints --check` calls `OpenAPIGenerator#stale?` to detect drift
    - `endpoints --cleanup` includes spec regeneration in its set of proposed fixes

13. **Serve spec and UI automatically in `Workbench::Server`**
    - `GET [base_path]/openapi.json` — serve `openapi.yml` (written at startup) as JSON
    - `GET [base_path]/docs` — serve a minimal HTML page embedding Swagger UI via CDN, pointed at `[base_path]/openapi.json`
    - Both routes are enabled by default; disable via `server.openapi: false` in `workbench.yml`

## Project Configuration (Forward Compatibility)

To support future features (database setup/teardown, per-pipeline config), introduce a lightweight project-level config file now, even if most keys are unused in Phase 1.

### `workbench.yml` (project-level config)

```yaml
# workbench.yml
project:
  name: my_workbench_project
  task_dir: tasks/
  pipeline_dir: pipelines/

server:
  port: 9292
  host: 0.0.0.0
  base_path: /api/v1   # prepended to all endpoint routes; omit for no prefix
  api_key: $API_KEY    # required; serve will not start without this set
  openapi: true        # set to false to disable /openapi.json and /docs routes

# Placeholder — used by future database feature
database:
  adapter: ~       # e.g. postgresql, sqlite
  url: ~           # connection string or env var reference like "$DATABASE_URL"
  migrations_dir: db/migrate/
```

### Pipeline-level config (forward-looking)

Individual pipeline YAML files may eventually accept a `config:` block:

```yaml
# pipelines/code_review.yml
name: code_review
config:
  database: true           # opt in to DB access when server starts
  timeout_seconds: 120
tasks:
  - name: parse_code
  - name: analyze_code
  - name: format_report
```

In Phase 1, the server reads `workbench.yml` for `server.port`, `server.host`, and `server.base_path`. `server.openapi` is consumed in Phase 6. The `database` and pipeline `config:` blocks are parsed but unused, so the schema is established without breaking future additions.

## Design Decisions

1. **`endpoints/` directory with one file per route**
   - Each endpoint is a first-class project file, checked into version control alongside `pipelines/` and `tasks/`. Developers can see what is exposed with a single `ls endpoints/`. File paths mirror URL paths, making the routing table self-documenting and producing clean diffs when endpoints are added or changed. The server can restart without re-running `deploy`.

2. **Roda over Sinatra/Rails**
   - Roda's routing-tree model is well-suited to dynamic route registration at startup. It adds minimal overhead and has no framework-level opinions about project structure.

3. **Synchronous by default**
   - Most workbench pipelines are short-lived CLI tools. Async is opt-in via `--async` to avoid complexity for the common case.

4. **Project config in `workbench.yml`, not in the manifest**
   - Server settings (port, host) and future database config belong to the project, not to individual deployments. Keeping them separate avoids coupling deployment metadata to infrastructure config.

5. **Naming conventions: underscores in Ruby, hyphens in URLs**
   - Task files, pipeline files, prompt files, and Ruby class names all follow standard Ruby/Rails conventions using underscores (`run_linter.rb`, `code_review.yml`). HTTP endpoint file names and URL paths use hyphens (`endpoints/run-linter.yml`, `/run-linter`), following REST API convention. The `deploy` command is the only place these worlds meet — it accepts an underscore name and handles the conversion automatically via `dasherize`. Developers working inside the framework never need to think about hyphens.

6. **Pipeline/task detection at deploy time**
   - The `deploy` command resolves whether a name is a pipeline or task and records `type:` in the manifest. The server reads this at startup rather than re-detecting at request time, which is faster and makes the manifest self-documenting.

7. **`server.base_path` as the namespace primitive**
   - Rather than building a namespace concept into the `deploy` command or endpoint file format, a single `base_path` key in `workbench.yml` prefixes all routes uniformly. This covers the dominant use case (API versioning) with a one-liner and can be extended per-endpoint in a future phase if needed.

8. **Tasks always execute inside a pipeline — never directly**
   - A current architectural constraint: tasks are never instantiated or run outside of a pipeline context. `Pipeline.lambda` exists to support single-task execution (e.g. `workbench start my_task`) while preserving the full pipeline execution environment — `@context`, telemetry, and the input/output lifecycle.
   - The server must follow the same rule: a `type: task` endpoint constructs a lambda pipeline wrapping that task rather than calling the task class directly. This keeps the execution path identical whether a pipeline was invoked from the CLI or via HTTP.

9. **`Workbench::Request` — HTTP context for pipelines (forward-looking, not in Phase 1–4)**
   - To support tasks that need awareness of the HTTP context (method, path, headers), a `Workbench::Request` struct will be introduced and attached to the pipeline when invoked via the server. Tasks may access it as `pipeline.request`, following Rails naming conventions (`request.method`, `request.path`, `request.headers`). When invoked from the CLI, `pipeline.request` is `nil`.
   - **Portability is the primary concern.** Tasks should treat `request` as optional context, not rely on it for core logic. The goal is that pipelines remain executable interchangeably across CLI, HTTP, and future contexts. Tasks that do use request context should declare it explicitly (e.g. a `uses_request_context` DSL annotation, analogous to `input`/`output`) so the dependency is visible and auditable.
   - This is intentionally deferred — introducing it too early risks developers building request-dependent tasks that can't be run from the CLI. The right moment is when there is a concrete use case that cannot be satisfied through inputs alone.

10. **OpenAPI spec on by default, no standalone command**
   - Documentation should require no extra effort from the developer. The spec is generated from metadata that already exists (input/output definitions), served at a well-known path, and accompanied by a browsable UI. Projects that do not want this exposed (e.g. internal-only servers) can set `server.openapi: false`.
   - There is no standalone `openapi` command — spec regeneration is a side effect of `deploy`, `undeploy`, and `serve` startup, keeping the spec in sync without a separate step.

11. **Spec drift detection: in-memory regeneration and diff**
   - `endpoints --check` detects a stale `openapi.yml` by regenerating the spec in memory and diffing it against the file on disk. This is simple to implement and requires no extra state.
   - **Alternative considered (checksum strategy):** At `deploy`/`undeploy` time, compute a checksum of the inputs that contributed to the spec (endpoint file contents + serialized `input_definitions` and `output_definitions` from all referenced tasks/pipelines) and store it alongside `openapi.yml`. `--check` then only needs to recompute the checksum and compare — no full regeneration required. This approach is faster at check time and works well in large projects, but introduces a second file to keep in sync. Prefer the in-memory diff for now; revisit if spec generation becomes slow.

12. **Authentication — required API key**
   - All requests must present `Authorization: Bearer <key>`. The key is set via `server.api_key` in `workbench.yml`. If `server.api_key` is absent, `serve` will refuse to start — authentication is not optional. Requests without a valid key receive a 401 response.

13. **Async persistence — flat files**
   - Async run status and output are written to files under `.workbench/runs/<run_id>.json`. This is simple, restartable, and requires no additional dependencies. The `.workbench/runs/` directory is gitignored. Migration to the future database feature is straightforward when the time comes.

14. **Hot reload — not in `serve`; deferred to a future `dev` command**
   - `serve` does not watch for file changes. A future `workbench dev` command will add hot-reloading behavior for local development. This keeps `serve` simple and production-appropriate.

15. **Pipeline input aggregation across tasks**
   - Same rule as the skills feature: only inputs from tasks that do not receive their value from a prior task's output are surfaced to the HTTP request body. Inputs satisfied internally by the pipeline are not exposed.

## Dependencies

- Existing: `thor`, `activesupport`
- New: `roda` (~> 3.0) — `rack` is a transitive dependency, not listed explicitly
- Optional (for `serve`): `puma` or `webrick` as the Rack handler

## File Changes Summary

| File | Change |
|------|--------|
| `lib/workbench/endpoint.rb` | New file — `Endpoint` class, file path↔route resolution, read/write |
| `lib/workbench/server.rb` | New file — `Server` (Roda app), dynamic route registration from `endpoints/` |
| `lib/workbench/openapi_generator.rb` | New file — `OpenAPIGenerator` class, spec generation from endpoint and task metadata |
| `lib/workbench/cli.rb` | Add `deploy`, `undeploy`, `endpoints` (with `--check`/`--cleanup`), `serve` commands |
| `lib/workbench.rb` | Require `endpoint`, `server`, and `openapi_generator` |
| `llm-workbench.gemspec` | Add `roda` dependency |
| `endpoints/` (user project) | New directory — one YAML file per route, checked into version control |
| `.workbench/runs/` (runtime) | Generated directory — one JSON file per async run; gitignored |
| `workbench.yml` (user project) | New project-level config (created by user, documented here) |

## Success Criteria

### Phase 1–3: Core Deployment
- [ ] `workbench deploy my_pipeline` writes a valid file to `endpoints/`
- [ ] `workbench deploy my_pipeline --path /tools/linter` writes to `endpoints/tools/linter.yml`
- [ ] `workbench serve` starts an HTTP server that responds to all routes in `endpoints/`
- [ ] POSTing valid JSON inputs to an endpoint runs the pipeline and returns outputs
- [ ] `workbench undeploy my_pipeline` removes the endpoint file; subsequent requests return 404
- [ ] `workbench endpoints` lists all active routes and their pipeline/task mappings

### Phase 2b: Endpoint Integrity (`endpoints --check` / `--cleanup`)
- [ ] `workbench endpoints` lists all routes with their method→pipeline/task mappings
- [ ] `workbench endpoints --check` reports `[missing]` for method entries referencing unknown pipelines/tasks
- [ ] `workbench endpoints --check` reports `[empty]` for endpoint files with no methods
- [ ] `workbench endpoints --check` reports `[duplicate]` when two files resolve to the same route
- [ ] `workbench endpoints --check` exits non-zero when any issue is found
- [ ] `workbench endpoints --cleanup` prints a dry-run summary before prompting for confirmation
- [ ] `workbench endpoints --cleanup` removes orphaned method entries and empty files after confirmation
- [ ] Cleanup never re-points or creates entries — only prunes

### Phase 4: Validation
- [ ] Missing required inputs return a 422 with an error message naming the missing field
- [ ] Server handles malformed JSON bodies gracefully (400)

### Phase 5: Async (stretch)
- [ ] `workbench deploy my_pipeline --async` causes the endpoint to return a `run_id` immediately
- [ ] `GET /<name>/status/:run_id` returns current status and outputs when complete

### Pre-merge: End-to-End Verification (PR 1)

Before PR 1 is marked ready, manually verify the full happy path against a real pipeline in the demo project:

- [ ] `workbench deploy <pipeline>` creates the correct endpoint file
- [ ] `workbench serve` starts without error and loads the endpoint
- [ ] A `curl` request with a valid API key and JSON inputs runs the pipeline and returns outputs
- [ ] A `curl` request without an API key returns 401
- [ ] `workbench undeploy <pipeline>` removes the file; subsequent requests return 404
- [ ] `workbench endpoints` correctly lists and then shows empty state after undeploy

Unit tests cover individual components; this step confirms the pieces work together. Consider scripting this as a `bin/smoke_test` script so it can be repeated easily after future changes.

### Phase 6: OpenAPI
- [ ] `workbench deploy` writes a valid `openapi.yml` as a side effect
- [ ] `workbench undeploy` updates `openapi.yml` as a side effect
- [ ] Spec includes all deployed endpoints with correct request/response schemas
- [ ] `workbench serve` regenerates `openapi.yml` at startup and serves it at `[base_path]/openapi.json`
- [ ] `workbench serve` serves Swagger UI at `[base_path]/docs`
- [ ] Setting `server.openapi: false` in `workbench.yml` disables both routes
- [ ] `workbench endpoints --check` reports `[stale-spec]` when `openapi.yml` is out of sync
- [ ] `workbench endpoints --cleanup` offers to regenerate `openapi.yml` when stale and applies after confirmation
