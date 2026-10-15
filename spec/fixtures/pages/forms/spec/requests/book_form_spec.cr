require "../spec_helper"
require "../support/rendered_form"

describe "The new book form" do
  it "creates a book when submitted as the page renders it" do
    Corretto.session do |client, db|
      page = client.get("/books/new")
      page.should render_page("New book")
      fill = {"title" => "Dune", "author" => "Frank Herbert"}
      created = submit_rendered_form(client, page, fill)
      created.should have_status(303)
      db.should have_row(App::Book, title: "Dune", author: "Frank Herbert", in_print: true)
    end
  end
end
