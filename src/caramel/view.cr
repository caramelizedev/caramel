require "html"
require "blueprint/html"
require "./html"
require "./islands"

module Caramel
  # A view is a Blueprint class (ADR 0018): its inputs are typed in
  # `initialize` and its markup is Crystal in `private def blueprint`.
  #
  #     class App::Views::Books::Show < App::ApplicationView
  #       def initialize(@book : App::Book)
  #       end
  #
  #       private def blueprint
  #         h1 { @book.title }
  #       end
  #     end
  #
  # Text and attribute values are escaped. `Caramel::HTML::Safe` and
  # Blueprint's `safe(...)` values are written as they are. A view renders
  # once: build a new one for each response.
  abstract class View
    include Blueprint::HTML

    # Writes an island (ADR 0005) in place.
    def island(component : String, props) : Nil
      raw Island.tag(component, props)
    end
  end
end

# Caramel's escaping contract, applied to Blueprint 1.1.0 (ADR 0018).
# Attribute values are escaped like text: Blueprint escaped only `"`, so `&`
# reached the browser raw and a stored `&amp;` came back as `&`. Attributes
# render per call: Blueprint cached every rendered attribute set in a
# process-wide hash, keyed by a 64-bit hash, that never evicted.
module Blueprint::HTML::AttributesRenderer
  def render(attributes : NamedTuple | Hash, to buffer : String::Builder) : Nil
    attributes.each { |name, value| append_attribute(buffer, name, value) }
  end

  private def append_value(buffer : String::Builder, value : String) : Nil
    ::HTML.escape(value, buffer)
  end
end
