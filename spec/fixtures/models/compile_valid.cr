require "./application_record"

record = Book.new(title: "A book", author: "An author")
record.valid?
record.save
record.delete
Book.where(title: "A book").order(created_at: :desc).to_a
Book.where(title: "A book").where(author: "An author").to_a
