require "./support/harness"

# A stage's result, as the report records it.
alias Stage = NamedTuple(elapsed_ms: Float64, exit_code: Int32, log: String)

# The view and controller edits that the warm rebuilds compile.
GRID         = %(section class: "welcome-grid")
MARKED_GRID  = %(comment "compiler-profile-view"\n      section class: "welcome-grid")
INDEX        = %(Views::Home::Index.new)
MARKED_INDEX = %(Views::Home::Index.new.to_s + "<!-- compiler-profile-controller -->")

repo = Caramel::Checks::REPO
installed = File.realpath(Caramel::Checks.toolchain_root)
root = Caramel::Checks.private_temp("caramel-compiler-profile-")
puts "Compiler profile: #{root}"
generator = File.join(root, "generate.cr")
new_project = Path[repo, "src/frappe/new_project"].relative_to(root).to_s
resource_generator = Path[repo, "src/frappe/resource_generator"].relative_to(root).to_s
# A backslash at a line's end joins it to the next line.
File.write(generator, <<-CR)
  require #{new_project.to_json}
  require #{resource_generator.to_json}

  project = Caramel::Frappe::NewProject.new(ARGV[0]).create("bookshelf", ARGV[1])
  generator = Caramel::Frappe::ResourceGenerator.new(ARGV[0])
  generator.generate(project, "Book", ["title:string", "author:string"])
  generator.generate(project, "Person", ["name:string", "age:int32", "total:int64", \
    "active:bool", "rating:float64?", "joined_at:time?"], plural: "people")
  if ARGV[2] == "22"
    ('A'..'T').each { |letter| generator.generate(project, "Benchmark\#{letter}", \
      ["title:string", "description:string"]) }
  end
  CR
generate = File.join(root, "generate")
build = Caramel::Checks.crystal(["build", generator, "-o", generate], timeout: 1.hour)
print build.stdout
STDERR.print build.stderr
raise "generator build failed" unless build.success?

scenarios = {} of String => Hash(String, Stage)
# ameba:disable Lint/UselessAssign -- read by the ensure below
complete = false
begin
  {2, 22}.each do |count|
    directory = File.join(root, count.to_s)
    Dir.mkdir(directory)
    project = File.join(directory, "bookshelf")
    generated = Caramel::Checks.run([generate, repo, project, count.to_s], timeout: 1.hour)
    print generated.stdout
    STDERR.print generated.stderr
    raise "project generation failed" unless generated.success?
    shards = Caramel::Checks.shards(["install", "--frozen"], chdir: project, timeout: 1.hour)
    print shards.stdout
    STDERR.print shards.stderr
    raise "shards install failed" unless shards.success?

    prefix = File.join(directory, "toolchain")
    Dir.mkdir(prefix)
    Dir.mkdir(File.join(prefix, "data"))
    File.symlink(File.join(installed, "data/installs"), File.join(prefix, "data/installs"))
    File.symlink(File.join(installed, "bin"), File.join(prefix, "bin"))
    environment = {"CARAMEL_TOOLCHAIN_ROOT" => prefix} of String => String?
    controller = File.join(project, "app/actions/home/show.cr")
    view = File.join(project, "app/views/home/index.cr")
    stages = scenarios[count.to_s] = {} of String => Stage
    {"cold", "unchanged_warm", "view_edit", "controller_edit"}.each do |stage|
      if stage == "view_edit"
        File.write(view, File.read(view).sub(GRID, MARKED_GRID))
      elsif stage == "controller_edit"
        File.write(controller, File.read(controller).gsub(INDEX, MARKED_INDEX))
      end
      log = File.join(directory, "#{stage}.log")
      application = File.join(directory, "application")
      command = ["build", "src/bookshelf.cr", "-D", "caramel_development",
                 "--stats", "--error-trace", "-o", application]
      started = Time.monotonic
      result = Caramel::Checks.crystal(command,
        chdir: project, env: environment, timeout: 180.seconds)
      elapsed_ms = (Time.monotonic - started).total_milliseconds
      File.write(log, result.stdout + result.stderr)
      stages[stage] = {
        elapsed_ms: elapsed_ms,
        exit_code:  result.status.exit_code,
        log:        File.basename(log),
      }
      puts "#{count} resources / #{stage}: #{elapsed_ms.round.to_i} ms"
      raise "compiler stage failed: #{stage}" unless result.success?
    end
  end
  complete = true
ensure
  report = File.join(root, "report.json")
  summary = {complete: complete, scenarios: scenarios, root: root}
  File.write(report, summary.to_pretty_json + "\n")
  puts "Saved compiler profile: #{report}"
end
