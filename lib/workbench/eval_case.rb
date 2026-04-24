module Workbench
  class EvalCase
    attr_reader :id, :group_name, :root_path, :files, :inputs, :outputs

    def initialize(id:, root_path:, files:, group_name: nil, inputs: [], outputs: [])
      @id         = id
      @group_name = group_name
      @root_path  = root_path.to_s
      @files      = files
      @inputs     = inputs
      @outputs    = outputs
    end
  end
end
