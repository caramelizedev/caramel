require "./installations"
require "./commands"

module Caramel::Frappe::Dispatch
  ENVIRONMENT_KEY = "CARAMEL_FRAPPE_DISPATCHED"
  RELEASE         = /\A[0-9]+\.[0-9]+\.[0-9]+(?:-[0-9A-Za-z.]+)?\z/

  # The `frappe` of the release a project pins in its shard.lock, when that
  # is another release than this one.
  def self.target(arguments : Array(String), directory : String = Dir.current, environment : ENV.class | Hash(String, String) = ENV) : String?
    return if environment[ENVIRONMENT_KEY]? == "1"
    return unless Commands.project?(arguments)
    pin = Project.pin(directory)
    return unless pin && pin.matches?(RELEASE) && pin != Caramel::VERSION

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
