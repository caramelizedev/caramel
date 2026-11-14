module Caramel
  # The ids a full spec run must name. `frappe corretto` with no paths fails unless
  # each one stands as a token in the description of an example that ran, as in
  # `it "refuses an unbalanced journal (AC-12)"`. A library declares its ids with a
  # block, which runs when the application is asked for them:
  #
  # ```
  # Caramel::SpecIds.declare { ["AC-12", "AC-13"] }
  # ```
  #
  # The application's `spec-ids` command prints them one a line, and Frappé reads
  # that. An application in which nothing declares an id is not checked.
  module SpecIds
    @@sources = [] of -> Array(String)

    # Adds the ids *source* returns to those a full spec run must name.
    def self.declare(&source : -> Array(String)) : Nil
      @@sources << source
    end

    # Every declared id once, in the order the sources were declared.
    def self.all : Array(String)
      @@sources.flat_map(&.call).uniq!
    end
  end
end
