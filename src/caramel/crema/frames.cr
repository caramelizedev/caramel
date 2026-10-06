module Caramel::Crema
  # One line of a Crystal backtrace: `app/x.cr:12:7 in 'App::X#run'`.
  record Frame, path : String, line : Int32, column : Int32?, label : String?, text : String

  module Frames
    PATTERN     = /\A(.+?):(\d+)(?::(\d+))?(?=\s|\z)(?: in '(.*)')?/
    DIRECTORIES = %w[app config src db]

    def self.parse(text : String) : Frame?
      match = PATTERN.match(text) || return
      column = match[3]?.try(&.to_i?)
      Frame.new(match[1], match[2].to_i? || 0, column, match[4]?, text)
    end

    # The project's root directory.
    def self.root : String
      File.expand_path(ENV["CARAMEL_PROJECT_ROOT"]? || Dir.current)
    end

    # True when *frame* is in the project's own app, config, src or db
    # directory. Crystal renders paths relative to the process's initial
    # directory, so normalize before classifying.
    def self.application?(frame : Frame, root : String) : Bool
      path = File.expand_path(frame.path, Process::INITIAL_PWD || Dir.current)
      DIRECTORIES.any? { |directory| path.starts_with?("#{root}/#{directory}/") }
    end

    # *path* relative to *root* when it is inside it.
    def self.relative(path : String, root : String) : String
      expanded = File.expand_path(path, Process::INITIAL_PWD || Dir.current)
      prefix = "#{root}/"
      expanded.starts_with?(prefix) ? expanded.lchop(prefix) : path
    end

    # The first frame of *frames* that belongs to the application.
    def self.first_application(frames : Array(String), root : String) : Frame?
      frames.each do |text|
        frame = parse(text)
        return frame if frame && application?(frame, root)
      end
      nil
    end
  end
end
