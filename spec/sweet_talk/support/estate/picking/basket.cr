module Estate
  within Picking do
    aggregate Basket, means: "the leaves one picker brought in from one bush" do
      has bush : Garden::Bush
      has weight : Grams

      event Weighed, carries: [weight], means: "a basket was put on the scales"

      to weigh(grams : Grams) do
        @weight = grams
        emit Weighed
      end

      finds heavy_ones, satisfying: Heavy
    end

    unit weigh_once(key : String, basket : Basket::Id, grams : Int32), changes: [Basket],
      locks: [basket], once_by: key, returns: Int32,
      otherwise: "That weighing was already made with another basket.",
      means: "weighs a basket once per key and answers its weight" do
      Basket.find(basket).weigh Grams.new(grams)
      Basket.find(basket).weight.raw
    end
  end
end
