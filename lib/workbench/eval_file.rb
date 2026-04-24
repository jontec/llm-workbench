require 'pathname'

module Workbench
  class EvalFile
    attr_reader :path

    def initialize(path, root_path)
      @path      = path.to_s
      @root_path = root_path.to_s
    end

    def name
      File.basename(@path)
    end

    def relative_path
      Pathname.new(@path).relative_path_from(Pathname.new(@root_path)).to_s
    end

    def read
      File.read(@path)
    end
  end
end
