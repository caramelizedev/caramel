module App::Probe
  struct Islands < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page "Islands", Views::Probe::Islands.new
    end
  end

  # Re-renders the counter island's panel with new props, or without it.
  struct IslandPanel < App::ApplicationAction
    contract do
      field label : String, min: 1, max: 40
      field version : Int32, min: 1
      field remove : Bool, default: false
    end

    def handle(contract : Contract)
      html = contract.remove ? %(<p id="island-removed">The counter island was removed.</p>) : island("ProbeCounter", {label: contract.label, version: contract.version})
      morph("#island-panel", with: html)
    end
  end
end
