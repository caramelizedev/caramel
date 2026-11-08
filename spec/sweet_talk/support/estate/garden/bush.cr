module Estate
  within Garden do
    aggregate Bush, means: "one tea bush in a row" do
      has row : Row
    end

    publishes Bush
  end
end
