struct Greetings::Show < GreetingsAction
  include Greetings::Signature

  contract do
    field name : String
  end

  def handle(contract : Contract)
    page "Hello", view("greetings/show", name: contract.name, footer: Caramel::HTML::Safe.new(signature))
  end
end
