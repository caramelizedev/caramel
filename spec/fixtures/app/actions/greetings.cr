abstract struct GreetingsAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end
