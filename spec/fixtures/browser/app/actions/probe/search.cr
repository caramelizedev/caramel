module App::Probe
  # Live-search panels whose swap style differs only by `mode`, so the
  # innerHTML panel is a control for what morphing preserves.
  module SearchPanel
    SWAPS = {"morph" => "innerMorph", "html" => "innerHTML"}

    private def search_panel(panel : String, text : String) : Views::Probe::SearchPanel
      label = text.empty? ? "Item" : text
      items = (1..40).map { |index| "#{label} #{index}" }
      Views::Probe::SearchPanel.new(panel, SWAPS[panel], text, items)
    end
  end

  struct Search < App::ApplicationAction
    include SearchPanel

    contract do
    end

    def handle(contract : Contract)
      page "Live search", Views::Probe::Search.new(search_panel("morph", ""), search_panel("html", ""))
    end
  end

  struct SearchResults < App::ApplicationAction
    include SearchPanel

    contract do
      field mode : String
      field q : String, max: 100, default: ""
    end

    def handle(contract : Contract)
      return not_found unless SWAPS.has_key?(contract.mode)
      page "Live search", search_panel(contract.mode, contract.q)
    end
  end
end
