module Bookshelf
  class Book
    property id : Int64?
    property title : String
    property author : String
    getter errors = [] of String

    def initialize(@title = "", @author = "", @id = nil)
    end

    def valid? : Bool
      @errors.clear
      @errors << "Title is required" if @title.strip.empty?
      @errors << "Author is required" if @author.strip.empty?
      @errors << "Title must be 200 characters or fewer" if @title.size > 200
      @errors << "Author must be 200 characters or fewer" if @author.size > 200
      @errors.empty?
    end
  end

  # Explicit parameterized persistence keeps the first reference app small.
  # This repository will be replaced by the separately tested model DSL.
  class BookStore
    def initialize(@db : DB::Database)
    end

    def all : Array(Book)
      @db.query_all("SELECT id, title, author FROM books ORDER BY created_at DESC, id DESC", as: {Int64, String, String}).map do |row|
        Book.new(row[1], row[2], row[0])
      end
    end

    def find(id : Int64) : Book?
      row = @db.query_one?("SELECT id, title, author FROM books WHERE id = $1", id, as: {Int64, String, String})
      row.try { |value| Book.new(value[1], value[2], value[0]) }
    end

    def save(book : Book) : Bool
      return false unless book.valid?
      if id = book.id
        result = @db.exec("UPDATE books SET title = $1, author = $2, updated_at = CURRENT_TIMESTAMP WHERE id = $3", book.title, book.author, id)
        if result.rows_affected != 1
          book.errors << "This book was deleted. Return to your bookshelf."
          return false
        end
      else
        book.id = @db.query_one("INSERT INTO books (title, author) VALUES ($1, $2) RETURNING id", book.title, book.author, as: Int64)
      end
      true
    end

    def delete(id : Int64) : Nil
      @db.exec("DELETE FROM books WHERE id = $1", id)
    end
  end
end
