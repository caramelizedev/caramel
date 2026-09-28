require "./html"

module Caramel
  # A rendered page: `body` is trusted HTML, normally `Caramel::View.render` output.
  record Page, title : String, body : String

  # One region of a multi-target response. `html` is trusted HTML.
  record Partial, target : String, html : String, swap : String = "innerMorph"

  # htmx 4 rewrites each `<hx-partial>` into `template[hx][type=partial]` and
  # swaps it into its own target, so one response can update several regions.
  module Hypermedia
    SWAPS            = %w[innerHTML outerHTML innerMorph outerMorph beforebegin afterbegin beforeend afterend delete none]
    MAX_TARGET_BYTES = 256

    def self.render(partials : Enumerable(Partial)) : String
      String.build do |io|
        partials.each do |partial|
          if partial.target.empty? || partial.target.bytesize > MAX_TARGET_BYTES
            raise ArgumentError.new("partial target must be 1 to #{MAX_TARGET_BYTES} bytes")
          end
          raise ArgumentError.new("unsupported partial swap: #{partial.swap}") unless SWAPS.includes?(partial.swap)
          io << %(<hx-partial hx-target=") << HTML.escape(partial.target) << %(" hx-swap=") << partial.swap << %(">)
          io << partial.html << "</hx-partial>"
        end
      end
    end
  end
end
