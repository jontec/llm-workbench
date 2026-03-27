# Pre-alpha Warning & Roadmap

## ⚠️ Warning

Please note: This repo is not ready for primetime and the gem it provides is not yet published on RubyGems.

In order to use it, you will need to checkout the code and point your Gemfile at a vendored copy (or use the Gemfile config to point at the repo URL):

```ruby
gem "llm-workbench", path: "vendor/llm-workbench"
```

Then get your bundle updated:
```
bundle install
```

Once that's complete, you can run it with:

```bash
bundle exec workbench start <name of task or pipeline>
```

## 🗺️ Roadmap

### Pre-alpha

- Basic test coverage for core primitives, especially for filesystem lookups
- ERB support for Prompts (currently is a no-op `file.read`)
- LLM Provider support and helpers (currently call LLMs on your own within the task)

### Later

#### Pipelines

- **Flow control support**: Enhancing pipeline syntax to include control flow

#### LLM Integration

- **LLM Output caching**: Likely integrating VCR to record and cache useful LLM outputs
- **ActiveRecord Support**: Focused initially on enabling state-dumping on errors for retries (avoid wasting expensive LLM outputs)
- **MLFlow Exporter**: Allow monitoring of Pipeline & Task execution from MLFlow

#### API Publishing

- **Async API execution**: `--async` flag for `deploy` — returns a `run_id` immediately and runs the pipeline in the background; status polling via `GET /<name>/status/:run_id`
- **OpenAPI spec generation**: Auto-generate `openapi.yml` on `deploy`/`undeploy`/`serve`; drift detection in `endpoints --check`; Swagger UI at `/docs`

# LLM Workbench

LLM Workbench is an opinionated framework designed to help you build flexible (and hopefully maintainable!) LLM-enabled pipelines in Ruby. You can run these pipelines one-off from the CLI or host them as HTTP API endpoints with a single command.

# Quickstart

## Installation

Install the Ruby gem:

```bash
gem install llm-workbench
```

Or add it to your bundle:

```bash
bundle add llm-workbench
```

## Getting Started

Inside your project directory root, create a `tasks/` directory and create a task:

```bash
mkdir tasks
vi tasks/my_task.rb
```

Create your Task as a subclass of the main Workbench::Task class. Declare inputs and outputs, and write your logic inside the `#run` method:

```ruby
require 'workbench'
class MyTask < Workbench::Task
  input :message
  output :result

  def run
    # Do something
    set_output :result, "Processed: #{fetch_input(:message)}"
  end
end
```

Next, define a new Pipeline in your pipeline directory using just your newly created Task:

```bash
mkdir pipelines
vi pipelines/my_pipeline.yml
```

Inside my_pipeline.yml:

```yaml
name: my_pipeline
description: |
  This pipeline runs a single task.
tasks:
  - name: my_task
```

Optional: Define a new Prompt for use with the same name, and access it in one line from your task:

```bash
mkdir prompts
vi my_task.v1.prompt.erb
```

Inside my_task.rb:

```ruby
require 'workbench'
class MyTask < Workbench::Task
  def run
    # Do something
    @prompt.render # gets the latest Prompt called "my_task"
  end
end
```

Run it! Use the command line tool to run your pipeline (launch from your project directory root):

```bash
workbench start my_pipeline
```

## Deploy Pipelines and Tasks as API Endpoints

Any pipeline or task can be deployed as an HTTP endpoint in a few steps.

**1. Add a `workbench.yml` to your project root:**

```yaml
project:
  name: my_workbench_project
  task_dir: tasks/
  pipeline_dir: pipelines/

server:
  port: 9292
  host: 0.0.0.0
  base_path: /api/v1   # optional; prepended to all routes
  api_key: $API_KEY    # required; set in your environment
```

**2. Deploy a pipeline as an endpoint:**

```bash
workbench deploy my_pipeline
# → writes endpoints/my-pipeline.yml
# → route: POST /api/v1/my-pipeline
```

**3. Start the server:**

```bash
workbench serve
# → Listening on 0.0.0.0:9292
```

**4. Call it:**

```bash
curl -X POST http://localhost:9292/api/v1/my-pipeline \
  -H "Authorization: Bearer $API_KEY" \
  -H "Content-Type: application/json" \
  -d '{"message": "hello"}'
```

```json
{
  "status": "ok",
  "pipeline": "my_pipeline",
  "outputs": {
    "result": "Processed: hello"
  }
}
```

**Other useful commands:**

```bash
workbench endpoints              # list all active routes
workbench endpoints --check      # validate endpoint integrity (CI-safe)
workbench endpoints --cleanup    # interactively fix issues
workbench undeploy my_pipeline   # remove an endpoint
```

Endpoint files live in `endpoints/` and are checked into version control alongside your pipelines and tasks. The file path encodes the HTTP route — `endpoints/tools/linter.yml` is served at `/tools/linter`.

# What is LLM Workbench?

## What Workbench Offers

### Primitives

The framework defines a few primitives to help you get started, largely inspired by the separation of concerns encouraged by MVC frameworks like Rails. (At this time, the gem does not directly integrate with Rails)

- **Pipeline**: A sequenced collection of Tasks, defined in YAML along with optional inputs and other run-time configurations for each Task
- **Task**: A self-contained set of Ruby code corresponding to a logical action, whether LLM-enabled or deterministic (e.g. simple parsing or processing). Tasks declare their `input` and `output` fields, which are used for pipeline state management and API input validation.
- **Prompt**: An ERB file containing a prompt for use in a Task, identified by its filename and optional properties included in its file extension, including:
    - **Version**: e.g. "v1" identifying a working version or series of prompts
    - **Model Provider**: A model provider like "OpenAI", "Anthropic," or "Google"
    - **Model**: A specific version of model like "gpt-4", "claude-3.7-sonnet", or "gemini-1.5-pro"
- **Schema**: A JSON schema that can be used with a Prompt inside a Task to constrain the output of an LLM response
- **Endpoint**: A YAML file in `endpoints/` that maps an HTTP method and route to a pipeline or task. Created by `workbench deploy` and loaded by `workbench serve`.
- **`workbench.yml`**: A project-level config file that sets server options (port, host, base path, API key) and project conventions (task/pipeline directories). Checked into version control.

Workbench provides useful tools (e.g. lookup, execution, and logging support) for each primitive that you can leverage inside the code you write for each Task.

### Integrated Capabilities

- **Structured Logging**: Workbench automatically maintains a structured logging hierarchy using OpenTelemetry's spans, to cover pipeline execution and nested task execution. Helpers are exposed to Tasks to add events, properties, and embedded spans.
    - Because it uses OpenTelemetry under the hood, Workbench's backend is pluggable and log data can be pushed to sources like Datadog or ML-native platforms, like MLFlow for monitoring and analysis
- **State management**: Pipelines and Tasks can accept inputs, and during a Pipeline's lifecycle, task outputs are automatically pushed to the default Pipeline context. Tasks have access to and can inspect the full stack--or prior tasks, if needed--through a Pipeline object exposed at runtime.
- **API publishing**: Any pipeline or task can be deployed as an authenticated HTTP endpoint using `workbench deploy` and served with `workbench serve` (backed by [Roda](https://roda.jeremyevans.net/)). Task and pipeline definitions are automatically aggregated and used to validate API requests and shape API output.

## License

LLM Workbench is licensed under the [Apache 2.0 License](LICENSE).

---

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.