require "./html"

module Caramel
  # A rendered page: `body` is trusted HTML, normally a rendered view.
  record Page, title : String, body : String do
    # The rendered body as trusted HTML, for a layout view: `raw page.html`.
    def html : HTML::Safe
      HTML::Safe.new(body)
    end
  end

  # One region of a multi-target response. `html` is trusted HTML, such as a
  # rendered view: `Partial.new("#roster", Views::Teams::Roster.new(team).to_s)`.
  record Partial, target : String, html : String, swap : String = "innerMorph"

  # htmx 4 rewrites each `<hx-partial>` into `template[hx][type=partial]` and
  # swaps it into its own target, so one response can update several regions.
  module Hypermedia
    SWAPS = %w[
      innerHTML outerHTML innerMorph outerMorph
      beforebegin afterbegin beforeend afterend
      delete none
    ]
    MAX_TARGET_BYTES = 256

    def self.render(partials : Enumerable(Partial)) : String
      String.build do |io|
        partials.each do |partial|
          if partial.target.empty? || partial.target.bytesize > MAX_TARGET_BYTES
            raise ArgumentError.new("partial target must be 1 to #{MAX_TARGET_BYTES} bytes")
          end
          unless SWAPS.includes?(partial.swap)
            raise ArgumentError.new("unsupported partial swap: #{partial.swap}")
          end
          target = HTML.escape(partial.target)
          io << %(<hx-partial hx-target="#{target}" hx-swap="#{partial.swap}">)
          io << partial.html << "</hx-partial>"
        end
      end
    end
  end
end
