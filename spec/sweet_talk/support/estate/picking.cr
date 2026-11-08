module Estate
  context Picking, follows: Garden, event_log: true, means: "the leaves picked each morning" do
    value Grams, Int32, at_least: 0, means: "a weight of picked leaves"

    event MorningStarted, means: "the morning's picking began"
    event Calibrated, against : Grams, means: "the scales were checked against a known weight"

    service start_morning(against : Grams),
      means: "starts the morning's picking with the scales checked" do
      emit MorningStarted
      emit Calibrated, against: against
    end
  end
end
