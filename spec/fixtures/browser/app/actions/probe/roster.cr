module App::Probe
  ROSTER = ["Ada Lovelace", "Grace Hopper"]

  struct Roster < App::ApplicationAction
    contract do
    end

    def handle(contract : Contract)
      page "Roster", view("probe/roster", names: ROSTER, list: Caramel::HTML::Safe.new(view("probe/_roster", names: ROSTER)))
    end
  end

  # One request, two disjoint targets with different swap styles.
  struct Enroll < App::ApplicationAction
    contract do
      field name : String, min: 1, max: 60
    end

    def handle(contract : Contract)
      members = ROSTER + [contract.name]
      partials([
        Caramel::Partial.new("#roster", view("probe/_roster", names: members), "innerMorph"),
        Caramel::Partial.new("#roster-count", members.size.to_s, "innerHTML"),
      ])
    end
  end
end
