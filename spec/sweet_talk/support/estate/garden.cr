module Estate
  context Garden, means: "the bushes the estate grows" do
    value Row, Int32, at_least: 1, means: "the row a bush grows in"
  end
end
