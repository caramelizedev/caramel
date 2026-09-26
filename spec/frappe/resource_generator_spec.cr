require "spec"
require "file_utils"
require "../../src/frappe/new_project"
require "../../src/frappe/resource_generator"

private def resource_project(&)
  parent = File.tempname("caramel-resource-")
  Dir.mkdir(parent)
  package = File.expand_path("../..", __DIR__)
  project = Caramel::Frappe::NewProject.new(package).create("bookshelf", File.join(parent, "bookshelf"))
  yield project, package
ensure
  FileUtils.rm_rf(parent) if parent
end

describe Caramel::Frappe::ResourceGenerator do
  it "generates readable typed CRUD and preserves custom routes and path helpers" do
    resource_project do |project, package|
      route = File.join(project.root, "config/routes.cr")
      File.open(route, "a") { |io| io.puts("# My existing route notes") }
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      paths = generator.generate(project, "Book", ["title:string", "author:string"], version: 20260919000001_i64)
      paths.should contain("app/models/book.cr")
      paths.should contain("app/actions/books.cr")
      paths.should contain("app/actions/books/index.cr")
      paths.should contain("spec/requests/books_spec.cr")
      paths.should contain("db/migrations/20260919000001_create_books.cr")
      File.read(route).should contain("# My existing route notes")
      File.read(route).should contain(%(get "/books/:id", App::Books::Show))
      File.read(File.join(project.root, "config/paths.cr")).should contain("Caramel.resource_paths :books, :book")
      %w(index show new edit _form).each do |view|
        File.file?(File.join(project.root, "app/views/books/#{view}.html.ecr")).should be_true
      end
      before = File.read(route)
      expect_raises(Caramel::Frappe::Error, "exists") { generator.generate(project, "Book", ["title:string"], version: 20260919000002_i64) }
      File.read(route).should eq(before)
      File.exists?(File.join(project.root, "db/migrations/20260919000002_create_books.cr")).should be_false
      expect_raises(Caramel::Frappe::Error, "version") { generator.generate(project, "Magazine", ["title:string"], version: 20260919000001_i64) }
    end
  end

  it "rejects malformed declarations, reserved fields and route conflicts before writing source" do
    resource_project do |project, package|
      generator = Caramel::Frappe::ResourceGenerator.new(package)
      ["../Book", "book", "ApplicationRecord", "Home"].each do |name|
        expect_raises(Caramel::Frappe::Error) { generator.generate(project, name, ["title:string"]) }
      end
      [["title:json"], ["id:int64"], ["save:string"], ["if:string"], ["to_s:string"], ["title:string", "title:string"], ["x:string:extra"], ["bad-name:string"]].each do |fields|
        expect_raises(Caramel::Frappe::Error) { generator.generate(project, "Book", fields) }
      end
      File.write(File.join(project.root, "config/routes.cr"), "# custom routes without a generation marker\n")
      expect_raises(Caramel::Frappe::Error, "marker") { generator.generate(project, "Book", ["title:string"]) }
      Dir.children(File.join(project.root, "app/models")).should eq(["application_record.cr"])
    end
  end

  it "supports every scalar, nullable values and explicit irregular plurals" do
    resource_project do |project, package|
      Caramel::Frappe::ResourceGenerator.new(package).generate(project, "Person", ["name:string", "age:int32", "total:int64", "active:bool", "rating:float64?", "joined_at:time?"], plural: "people")
      model = File.read(File.join(project.root, "app/models/person.cr"))
      model.should contain("field rating : Float64?")
      model.should contain("field joined_at : Time?")
      File.read(File.join(project.root, "config/routes.cr")).should contain("App::People::Index")
    end
  end
end
