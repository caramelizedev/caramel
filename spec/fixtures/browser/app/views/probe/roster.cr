module App::Views::Probe
  class Roster < App::ApplicationView
    def initialize(@names : Array(String))
    end

    private def blueprint
      h1 { "Roster" }
      p(id: "roster-note", class: "probe-note") { "This region is not part of any response." }
      p do
        plain "Members: "
        output(id: "roster-count") { @names.size.to_s }
      end
      ul(id: "roster") { render RosterMembers.new(@names) }
      form id: "enroll", hx_post: "/probe/roster" do
        label(for: "enroll-name") { "Name" }
        input id: "enroll-name", name: "name", autocomplete: "off"
        button(id: "enroll-submit", type: "submit") { "Enroll" }
      end
    end
  end

  # The roster's items, also rendered alone for the #roster partial.
  class RosterMembers < App::ApplicationView
    def initialize(@names : Array(String))
    end

    private def blueprint
      @names.each { |name| li { name } }
    end
  end
end
