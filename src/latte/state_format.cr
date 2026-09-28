require "../caramel/version"

module Caramel::Latte
  # Caramel's persistent state files carry a format version (ADR 0016). A
  # newer release may introduce a newer format; this release then refuses the
  # file instead of misreading it or writing it back in its own format.
  module StateFormat
    class Newer < Exception
    end

    def self.check!(path : String, version : Int, supported : Int) : Nil
      return if version == supported
      if version > supported
        raise Newer.new("#{path} was written by a newer Caramel (format #{version}); Caramel #{Caramel::VERSION} reads format #{supported}. Use the newest installed Caramel.")
      end
      raise ArgumentError.new("#{path} has an unknown format version #{version}")
    end
  end
end
