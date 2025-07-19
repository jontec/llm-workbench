class OpenaiProvider < Workbench::LLMProvider
  def self.models
    ["gpt-4", "gpt-3o", "gpt-4o", "gpt-4o-mini"]
  end
end