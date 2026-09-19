require "../../src/frappe/new_project"
require "../../src/frappe/resource_generator"

project = Caramel::Frappe::NewProject.new(File.expand_path("../..", __DIR__)).create("bookshelf", ARGV[0])
if ARGV.includes?("--resources")
  generator = Caramel::Frappe::ResourceGenerator.new(File.expand_path("../..", __DIR__))
  generator.generate(project, "Book", ["title:string", "author:string"])
  generator.generate(project, "Person", ["name:string", "age:int32", "total:int64", "active:bool", "rating:float64?", "joined_at:time?"], plural: "people")
end
puts project.root
