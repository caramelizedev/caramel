require "uri"

module Caramel::Crema
  # Turns a `path:line:column` into a link that opens the file in the
  # developer's editor. `CARAMEL_EDITOR` names a preset or a template; Zed is
  # the default. In a template, `{path}` is the absolute path (it starts with
  # `/`), and `{line}` and `{column}` are numbers.
  struct Editor
    PRESETS = {
      "zed"      => "zed://file{path}:{line}:{column}",
      "vscode"   => "vscode://file{path}:{line}:{column}",
      "cursor"   => "cursor://file{path}:{line}:{column}",
      "sublime"  => "subl://open?url=file://{path}&line={line}&column={column}",
      "textmate" => "txmt://open?url=file://{path}&line={line}&column={column}",
      "idea"     => "idea://open?file={path}&line={line}&column={column}",
    }
    DEFAULT = "zed"

    getter template : String

    def initialize(@template : String)
    end

    # The editor *value* names: a preset, a template containing `{path}`, or
    # Zed when it is nil, empty or neither.
    def self.from(value : String?) : Editor
      named = value.try(&.strip)
      return new(PRESETS[DEFAULT]) if named.nil? || named.empty?

      template = PRESETS[named]? || (named.includes?("{path}") ? named : PRESETS[DEFAULT])
      new(template)
    end

    # The link for *path*, which must be absolute, or an empty string.
    def link(path : String, line : Int32, column : Int32 = 1) : String
      return "" unless path.starts_with?("/")

      @template
        .gsub("{path}", URI.encode_path(path))
        .gsub("{line}", line.to_s)
        .gsub("{column}", column.to_s)
    end
  end
end
