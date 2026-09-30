require "json"
require "./html"

module Caramel
  # Server-rendered mount points for client components registered through
  # `CaramelIslands.define` (src/caramel/islands.js). Morphs update `props`
  # but leave the client-rendered children alone.
  module Island
    NAME = /\A[A-Z][A-Za-z0-9]{0,63}\z/

    def self.tag(component : String, props) : HTML::Safe
      unless component.matches?(NAME)
        raise ArgumentError.new("island component must be a PascalCase name: #{component}")
      end
      escaped = HTML.escape(props.to_json)
      attributes = %(component="#{component}" props="#{escaped}" hx-morph-skip-children)
      HTML::Safe.new(%(<caramel-island #{attributes}></caramel-island>))
    end
  end
end
