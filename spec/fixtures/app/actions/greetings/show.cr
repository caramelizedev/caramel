struct Greetings::Show < GreetingsAction
  contract do
    field name : String
  end

  def handle(contract : Contract)
    page "Hello", Views::Greetings::Show.new(contract.name)
  end
end
