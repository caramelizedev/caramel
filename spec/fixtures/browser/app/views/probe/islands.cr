module App::Views::Probe
  class Islands < App::ApplicationView
    private def blueprint
      h1 { "Islands" }
      div id: "island-panel", class: "probe-panel" do
        island "ProbeCounter", {label: "first", version: 1}
      end
      button(id: "island-morph", type: "button", hx_get: "/probe/islands/panel?label=second&version=2") { "Re-render with new props" }
      button(id: "island-remove", type: "button", hx_get: "/probe/islands/panel?label=gone&version=3&remove=true") { "Remove the island" }
      div id: "late-panel", class: "probe-panel" do
        island "LateProbe", {label: "late"}
      end
      button(id: "define-late", type: "button") { "Define LateProbe" }
    end
  end
end
