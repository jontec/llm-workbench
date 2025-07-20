# Pre-alpha Warning & Roadmap

## ⚠️ Warning

Please note: This repo is not ready for primetime and the gem it provides is not yet published on RubyGems.

In order to use it, you will need to checkout the code and point your Gemfile at a vendored copy (or use the Gemfile config to point at the repo URL):

```ruby
gem "llm-workbench", path: "vendor/llm-workbench"
```

Then get your bundle updated:
```
bundle install
```

Once that’s complete, you can run it with:

```bash
bundle exec workbench start <my task or pipeline>
```

## 🗺️ Roadmap

### Pre-alpha

- Basic test coverage for core primitives, especially for filesystem lookups
- ERB support for Prompts (currently is a no-op `file.read`)
- LLM Provider support and helpers (currently call LLMs on your own within the task)

### Later

#### Workbench Core

- **API publishing support**: Likely using roda

#### Pipelines

- **Flow control support**: Enhancing pipeline syntax to include control flow

#### LLM Integration

- **LLM Output caching**: Likely integrating VCR to record and cache useful LLM outputs
- **ActiveRecord Support**: Focused initially on enabling state-dumping on errors for retries (avoid wasting expensive LLM outputs)
- **MLFlow Exporter**: Allow monitoring of Pipeline & Task execution from MLFlow

# LLM Workbench

LLM Workbench is an opinionated framework designed to help you build flexible (and hopefully maintainable!) LLM-enabled pipelines in Ruby. You can run these pipelines one-off or automatically host them as individual API endpoints.

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

Create your Task as a subclass of the main Workbench::Task class, and start writing your code inside the `#run` method:

```ruby
require 'workbench'
class MyTask < Workbench::Task
  def run
    # Do something
  end
end
```

Next, define a new Pipeline in your pipeline directory using just your newly created Task:

```bash
mkdir pipeline
vi pipelines/my_pipeline.yaml
```

Inside my_pipeline.yaml:

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

# What is LLM Workbench?

## What Workbench Offers

### Primitives

The framework defines a few primitives to help you get started, largely inspired by the separation of concerns encouraged by MVC frameworks like Rails. (At this time, the gem does not directly integrate with Rails)

- **Pipeline**: A sequenced collection of Tasks, defined in YAML along with optional inputs and other run-time configurations for each Task
- **Task**: A self-contained set of Ruby code corresponding to a logical action, whether LLM-enabled or deterministic (e.g. simple parsing or processing)
- **Prompt**: An ERB file containing a prompt for use in a Task, identified by its filename and optional properties included in its file extension, including:
    - **Version**: e.g. “v1” identifying a working version or series of prompts
    - **Model Provider**: A model provider like “OpenAI”, “Anthropic,” or “Google”
    - **Model**: A specific version of model like “gpt-4”, “claude-3.7-sonnet”, or “gemini-1.5-pro”
- **Schema**: A JSON schema that can be used with a Prompt inside a Task to constrain the output of an LLM response

Workbench provides useful tools (e.g. lookup, execution, and logging support) for each primitive that you can leverage inside the code you write for each Task.

### Integrated Capabilities

- **Structured Logging**: Workbench automatically maintains a structured logging hierarchy using OpenTelemetry’s spans, to cover pipeline execution and nested task execution. Helpers are exposed to Tasks to add events, properties, and embedded spans.
    - Because it uses OpenTelemetry under the hood, Workbench’s backend is pluggable and log data can be pushed to sources like Datadog or ML-native platforms, like MLFlow for monitoring and analysis
- **State management**: Pipelines and Tasks can accept inputs, and during a Pipeline’s lifecycle, task outputs are automatically pushed to the default Pipeline context. Tasks have access to and can inspect the full stack or prior tasks, if needed through a Pipeline object exposed at runtime.
- **API publishing**: Tasks and Pipelines can be directly published
    - Each Task may define inputs and outputs that make API definitions automatically discoverable
    - Inputs and outputs can cascade across a Pipeline enabling publishing of complex workflows

## License

LLM Workbench is licensed under the [Apache 2.0 License](LICENSE).

---

## Contributing

Pull requests are welcome! For major changes, please open an issue first to discuss what you would like to change.