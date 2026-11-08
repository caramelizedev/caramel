module Estate
  within Picking do
    specification Heavy, on: Basket, where: {weight: Grams.new(500)..},
      means: "a basket of half a kilo or more"
  end
end
