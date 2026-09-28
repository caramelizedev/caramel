module App::Views::Probe
  class Search < App::ApplicationView
    def initialize(@morph : SearchPanel, @html : SearchPanel)
    end

    private def blueprint
      h1 { "Live search" }
      p(class: "probe-note") { "Each panel swaps itself on input; only the swap style differs." }
      section(id: "search-morph", class: "probe-panel", aria_label: "Morphing search") { render @morph }
      section(id: "search-html", class: "probe-panel", aria_label: "Replacing search") { render @html }
    end
  end

  # One search box and its results; `swap` is the only difference between
  # the two panels.
  class SearchPanel < App::ApplicationView
    def initialize(@mode : String, @swap : String, @query : String, @results : Array(String))
    end

    private def blueprint
      label(for: "search-#{@mode}-q") { "Search with #{@swap}" }
      input id: "search-#{@mode}-q", name: "q", type: "search", value: @query, autocomplete: "off",
        hx_get: "/probe/search/#{@mode}", hx_trigger: "input changed delay:150ms", hx_target: "#search-#{@mode}", hx_swap: @swap
      ul id: "search-#{@mode}-results", class: "probe-results", data_query: @query do
        @results.each { |result| li { result } }
      end
    end
  end
end
