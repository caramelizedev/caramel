require "./installations"

module Caramel::Frappe::Dispatch
  ENVIRONMENT_KEY = "CARAMEL_FRAPPE_DISPATCHED"
  PROJECT_COMMANDS = %w(setup dev make migrate seed routes test db logs doctor open lsp)
  RELEASE = /\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?\z/

  def self.target(arguments : Array(String), directory : String = Dir.current, environment : ENV.class | Hash(String, String) = ENV) : String?
    return nil if environment[ENVIRONMENT_KEY]? == "1"
    command = arguments.first?
    return nil unless command && PROJECT_COMMANDS.includes?(command)
    return nil if arguments[0..1] == ["lsp", "install"]
    path = File.join(directory, ".caramel-version")
    info = File.info?(path, follow_symlinks: false)
    return nil unless info && info.file? && info.size <= 64
    pin = File.read(path).strip
    return nil unless pin.matches?(RELEASE) && pin != Caramel::VERSION

    root = Installations.new(environment["CARAMEL_HOME"]?).lookup(pin)
    unless root
      raise Error.new("Project requires Caramel #{pin}, but no Caramel installation is registered for it. Run frappe installations register from a Caramel #{pin} checkout.")
    end
    binary = File.join(root, "bin/frappe")
    target = File.info?(binary, follow_symlinks: false)
    unless target && target.file? && File::Info.executable?(binary)
      raise Error.new("Registered Caramel #{pin} installation has no executable #{binary}; run scripts/build-frappe there, then frappe installations register.")
    end
    binary
  end
end
