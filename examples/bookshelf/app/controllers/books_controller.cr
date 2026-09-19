module Bookshelf
  class BooksController < Caramel::Controller
    def initialize(request : HTTP::Request, csrf : Caramel::CSRF, @books : BookStore)
      super(request, csrf)
    end

    def index : Caramel::Response
      books = @books.all
      content = Caramel::View.render "#{__DIR__}/../views/books/index.html.ecr"
      page(content, "Your bookshelf")
    end

    def show(id : Int64) : Caramel::Response
      book = @books.find(id)
      return Caramel::Response.new(404, "Book not found") unless book
      content = Caramel::View.render "#{__DIR__}/../views/books/show.html.ecr"
      page(content, book.title)
    end

    def new : Caramel::Response
      edit_form(Book.new, "Add a book", "/books", "POST")
    end

    def edit(id : Int64) : Caramel::Response
      book = @books.find(id)
      return Caramel::Response.new(404, "Book not found") unless book
      edit_form(book, "Edit book", "/books/#{id}", "PATCH")
    end

    def create : Caramel::Response
      form = parse_form("book", ["title", "author"])
      book = Book.new(form["title"], form["author"])
      if form.valid? && @books.save(book)
        Caramel::Response.redirect("/books/#{book.id}")
      else
        book.valid?
        book.errors.concat(form.errors)
        edit_form(book, "Add a book", "/books", "POST", 422)
      end
    end

    def change(id : Int64) : Caramel::Response
      form = parse_form("book", ["title", "author"], required_fields: [] of String)
      book = @books.find(id)
      return Caramel::Response.new(404, "Book not found") unless book
      return Caramel::Response.new(422, "Invalid form fields") unless form.valid?
      case form.method(@request.method)
      when "DELETE"
        @books.delete(id)
        Caramel::Response.redirect("/books")
      when "PATCH", "PUT"
        book.title, book.author = form["title"], form["author"]
        if @books.save(book)
          Caramel::Response.redirect("/books/#{id}")
        else
          edit_form(book, "Edit book", "/books/#{id}", "PATCH", 422)
        end
      else
        Caramel::Response.new(405, "Use the edit or delete form")
      end
    end

    private def edit_form(book : Book, title : String, action : String, method : String, status = 200) : Caramel::Response
      content = Caramel::View.render "#{__DIR__}/../views/books/form.html.ecr"
      page(content, title, status)
    end

    private def page(content : String, title : String, status = 200) : Caramel::Response
      body = Caramel::HTML::Safe.new(content)
      full = Caramel::View.render "#{__DIR__}/../views/layouts/application.html.ecr"
      # htmx extracts and removes this title before swapping a targeted fragment.
      partial = "<title>#{Caramel::HTML.escape(title)} · Bookshelf</title>#{content}"
      html(full, partial, status)
    end
  end
end
