require "../../../src/caramel"

module Paths
  Caramel.resource_paths :books, :book
  extend self
end

Paths.book_path("42")
