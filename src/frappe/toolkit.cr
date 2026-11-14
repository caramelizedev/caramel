require "file_utils"
require "random/secure"
require "./error"
require "./mrdp"
require "./terminal"
require "../latte/paths"

module Caramel::Frappe
  # What a generator needs, whether Frappé defines it or a shard ships it as its tool
  # program (ShardTool): where the project is and who reads the output, the lines of a
  # result and of a failure, generated files written all at once or not at all, a
  # library's require line in config/application.cr, and the closing `Next:` block.
  #
  # A tool program requires it from the application's copy of the framework, and reads
  # MRDP beside it for the line that closes an agent's success:
  #
  # ```
  # require "caramel/frappe/toolkit"
  #
  # kit = Caramel::Frappe::Toolkit
  # files = {"config/notes.cr" => "Notes.configure\n"}
  # kit.publish(kit.root, files)
  # kit.generated(STDOUT, files.keys)
  # Caramel::Frappe::MRDP.ok(STDOUT, "notes:install", "1 file") if kit.agent?
  # ```
  module Toolkit
    CONFIG          = "config/application.cr"
    CARAMEL_REQUIRE = %(require "caramel")

    # The variables that tell a tool program the project's root, that an agent reads its
    # output, and that a person's output takes no colour.
    ROOT        = "CARAMEL_PROJECT_ROOT"
    DIAGNOSTICS = "CARAMEL_DIAGNOSTICS"
    NO_COLOR    = "NO_COLOR"

    # What Frappé adds to the environment of a tool program it runs in the project at
    # *root*, once it has chosen who reads the output as it does for its own commands.
    def self.environment(root : String, agent : Bool, color : Bool) : Hash(String, String)
      values = {ROOT => root}
      values[DIAGNOSTICS] = "mrdp" if agent
      values[NO_COLOR] = "1" unless color
      values
    end

    # The root of the project the command runs in.
    def self.root(environment : ENV.class | Hash(String, String) = ENV) : String
      environment[ROOT]? || Dir.current
    end

    # Whether an agent reads the output: MRDP lines, no colour and no `Next:` block.
    def self.agent?(environment : ENV.class | Hash(String, String) = ENV) : Bool
      environment[DIAGNOSTICS]? == "mrdp"
    end

    # Whether to colour what a person reads on *io*.
    def self.color?(io : IO = STDOUT,
                    environment : ENV.class | Hash(String, String) = ENV) : Bool
      !agent?(environment) && Terminal.color?(io, environment)
    end

    # Prints the paths a generator wrote, one `Generated PATH` line each.
    def self.generated(io : IO, files : Enumerable(String)) : Nil
      files.each { |path| io.puts("Generated #{path}") }
    end

    # Prints why *command*, written without `frappe`, failed. A person reads *message*
    # and then *fix*, each on its own line; an agent reads the MRDP diagnostic
    # `ERR code at frappe command` with them as MSG and FIX.
    def self.failed(io : IO,
                    command : String,
                    message : String,
                    *,
                    agent : Bool,
                    fix : String? = nil,
                    code : String = "USAGE") : Nil
      unless agent
        io.puts(message)
        io.puts(fix) if fix
        return
      end
      fields = [{"MSG", message}]
      fields << {"FIX", fix} if fix
      MRDP.write(io, code, "frappe #{command}", fields)
    end

    # The commands to run next: {command, purpose} pairs aligned in two columns,
    # a step with an empty purpose printed as written, then each note as a paragraph.
    def self.next_steps(io : IO,
                        steps : Array(Tuple(String, String)),
                        notes : Array(String) = [] of String) : Nil
      width = steps.reject(&.[1].empty?).max_of?(&.[0].size) || 0
      io.puts
      io.puts("Next:")
      steps.each do |command, purpose|
        io.puts(purpose.empty? ? "  #{command}" : "  #{command.ljust(width)}  #{purpose}")
      end
      notes.each do |note|
        io.puts
        Terminal.wrap(note, 80).each { |line| io.puts(line) }
      end
    end

    # *config*, the text of config/application.cr, with *line* on the line after its
    # `require "caramel"`, where every generator puts a library's require; *config* as
    # it is when it already holds *line*. Publish the result with *config* as the
    # original of CONFIG. Raises Error unless `require "caramel"` is there exactly once.
    def self.required(config : String, line : String) : String
      lines = config.lines
      return config if lines.includes?(line)
      unless lines.count(CARAMEL_REQUIRE) == 1
        raise Error.new("#{CONFIG} needs exactly one #{CARAMEL_REQUIRE}; " \
                        "add #{line} after it by hand")
      end
      config.sub(/^#{Regex.escape(CARAMEL_REQUIRE)}$/m, "#{CARAMEL_REQUIRE}\n#{line}")
    end

    # Refuses a path of the project at *root* that passes through a symlink.
    def self.validate_path(root : String, relative : String) : Nil
      current = root
      relative.split('/').each do |part|
        current = File.join(current, part)
        if info = File.info?(current, follow_symlinks: false)
          raise Error.new("Generator refuses symlinked paths: #{relative}") if info.symlink?
        end
      end
    end

    # Writes *files*, content by path from *root*, all at once or not at all. A path in
    # *originals* is an existing file to replace, with the content it was planned from;
    # any other path must not exist. Raises Error, with the project as it was, when a
    # new file's path is taken, a planned file has changed, or a write fails.
    def self.publish(root : String,
                     files : Hash(String, String),
                     originals : Hash(String, String) = {} of String => String) : Nil
      preflight(root, files, originals)
      directory = Latte::StateSecurity.ensure_owned_directory(File.join(root, ".caramel"))
      lock_path = File.join(directory, "generation.lock")
      raise Error.new("Generator lock must be a regular file") if File.symlink?(lock_path)
      File.open(lock_path, "a", perm: 0o600) do |lock|
        lock.flock_exclusive do
          preflight(root, files, originals)
          stage = File.join(directory, "generate-#{Random::Secure.hex(8)}")
          Dir.mkdir(stage, 0o700)
          published = [] of String
          begin
            place(root, stage, files, originals, published)
          rescue ex
            withdraw(root, published, files, originals)
            raise ex
          ensure
            FileUtils.rm_rf(stage)
          end
        end
      end
    end

    private def self.preflight(root : String,
                               files : Hash(String, String),
                               originals : Hash(String, String)) : Nil
      # Repeat the version check while holding the publication lock: another
      # generator may have planned a different resource in the same second.
      files.each_key do |relative|
        next unless relative.starts_with?("db/migrations/")
        version = File.basename(relative).split('_', 2).first
        unless Dir.glob(File.join(root, "db/migrations/#{version}_*.cr")).empty?
          raise Error.new("Migration version already exists; retry generation")
        end
      end
      files.each_key do |relative|
        validate_path(root, relative)
        path = File.join(root, relative)
        if original = originals[relative]?
          unless File.file?(path) && File.read(path) == original
            raise Error.new("Source changed while planning generation: #{relative}")
          end
        elsif File.info?(path, follow_symlinks: false)
          raise Error.new("File already exists: #{relative}; source was preserved")
        end
      end
    end

    # Stages *files* under *stage*, then moves each into the project, naming it in
    # *published* once it is there.
    private def self.place(root : String,
                           stage : String,
                           files : Hash(String, String),
                           originals : Hash(String, String),
                           published : Array(String)) : Nil
      files.each do |relative, content|
        path = File.join(stage, relative)
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, content)
      end
      files.each_key do |relative|
        path = File.join(root, relative)
        FileUtils.mkdir_p(File.dirname(path))
        if originals.has_key?(relative)
          unless File.read(path) == originals[relative]
            raise Error.new("Source changed while generating: #{relative}")
          end
          File.rename(File.join(stage, relative), path)
        else
          File.link(File.join(stage, relative), path)
        end
        published << relative
      end
    end

    # Puts back what *published* replaced and deletes what it added, leaving any file
    # that no longer holds what the generator wrote.
    private def self.withdraw(root : String,
                              published : Array(String),
                              files : Hash(String, String),
                              originals : Hash(String, String)) : Nil
      published.reverse_each do |relative|
        path = File.join(root, relative)
        next unless File.file?(path) && File.read(path) == files[relative]
        if original = originals[relative]?
          File.write(path, original)
        else
          File.delete(path)
        end
      end
    end
  end
end
