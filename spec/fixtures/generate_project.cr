require "../../src/frappe/new_project"
require "../../src/frappe/resource_generator"

root = File.expand_path("../..", __DIR__)
project = Caramel::Frappe::NewProject.new(root).create("bookshelf", ARGV[0])
if ARGV.includes?("--resources")
  generator = Caramel::Frappe::ResourceGenerator.new(root)
  generator.generate(project, "Book", ["title:string", "author:string"])
  person = %w[name:string age:int32 total:int64 active:bool rating:float64? joined_at:time?]
  generator.generate(project, "Person", person, plural: "people")
end
puts project.root
