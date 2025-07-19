require_relative "lib/workbench/version"
Gem::Specification.new do |spec|
  spec.name          = "llm-workbench"
  spec.version       = Workbench::VERSION
  spec.authors       = ["Your Name"]
  spec.email         = ["you@example.com"]
  spec.summary       = "LLM-powered pipelines with reusable, modular tasks."
  spec.description   = "A framework to define and execute YAML-configured LLM pipelines with versioned prompts, task-level logging, and CLI utilities."
  spec.homepage      = "https://github.com/jontec/llm-workbench"
  spec.license       = "Apache-2.0"

  spec.required_ruby_version = ">= 2.7"

  spec.files         = Dir["lib/**/*", "bin/*", "llm-workbench.gemspec"]
  spec.executables   = ["workbench"]
  spec.bindir        = "bin"
  spec.require_paths = ["lib"]

  spec.add_dependency "thor", "~> 1.0"
  spec.add_dependency "activesupport", ">= 8.0"
  spec.add_dependency "json-schema", ">= 5.2"
  spec.add_dependency "opentelemetry-sdk", ">= 1.8"
end