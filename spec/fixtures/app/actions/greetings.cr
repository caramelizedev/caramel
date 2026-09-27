abstract struct GreetingsAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

module Greetings::Signature
  private def signature : String
    view("greetings/signature")
  end
end
