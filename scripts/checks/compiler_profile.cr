require "./support/harness"

repo = Caramel::Checks::REPO
installed = File.realpath(Caramel::Checks.toolchain_root)
root = Caramel::Checks.private_temp("caramel-compiler-profile-")
puts "Compiler profile: #{root}"
generator = File.join(root, "generate.cr")
new_project = Path[repo, "src/frappe/new_project"].relative_to(root).to_s
resource_generator = Path[repo, "src/frappe/resource_generator"].relative_to(root).to_s
File.write(generator, "require #{new_project.to_json}\nrequire #{resource_generator.to_json}\n\n" + <<-'CR')
  project = Caramel::Frappe::NewProject.new(ARGV[0]).create("bookshelf", ARGV[1])
  generator = Caramel::Frappe::ResourceGenerator.new(ARGV[0])
  generator.generate(project, "Book", ["title:string", "author:string"])
  generator.generate(project, "Person", ["name:string", "age:int32", "total:int64", "active:bool", "rating:float64?", "joined_at:time?"], plural: "people")
  if ARGV[2] == "22"
    ('A'..'T').each { |letter| generator.generate(project, "Benchmark#{letter}", ["title:string", "description:string"]) }
  end
  CR
build = Caramel::Checks.crystal(["build", generator, "-o", File.join(root, "generate")], timeout: 1.hour)
print build.stdout
STDERR.print build.stderr
raise "generator build failed" unless build.success?

scenarios = {} of String => Hash(String, NamedTuple(elapsed_ms: Float64, exit_code: Int32, log: String))
# ameba:disable Lint/UselessAssign
complete = false
begin
  {2, 22}.each do |count|
    directory = File.join(root, count.to_s)
    Dir.mkdir(directory)
    project = File.join(directory, "bookshelf")
    generated = Caramel::Checks.run([File.join(root, "generate"), repo, project, count.to_s], timeout: 1.hour)
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
    template = File.join(project, "app/views/home/index.html.ecr")
    stages = scenarios[count.to_s] = {} of String => NamedTuple(elapsed_ms: Float64, exit_code: Int32, log: String)
    {"cold", "unchanged_warm", "template_edit", "controller_edit"}.each do |stage|
      if stage == "template_edit"
        File.write(template, File.read(template) + "\n<!-- compiler-profile-template -->\n")
      elsif stage == "controller_edit"
        File.write(controller, File.read(controller).gsub(%(view("home/index")), %(view("home/index") + "<!-- compiler-profile-controller -->")))
      end
      log = File.join(directory, "#{stage}.log")
      command = ["build", "src/bookshelf.cr", "-D", "caramel_development", "--stats", "--error-trace", "-o", File.join(directory, "application")]
      started = Time.monotonic
      result = Caramel::Checks.crystal(command, chdir: project, env: environment, timeout: 180.seconds)
      elapsed_ms = (Time.monotonic - started).total_milliseconds
      File.write(log, result.stdout + result.stderr)
      stages[stage] = {elapsed_ms: elapsed_ms, exit_code: result.status.exit_code, log: File.basename(log)}
      puts "#{count} resources / #{stage}: #{elapsed_ms.round.to_i} ms"
      raise "compiler stage failed: #{stage}" unless result.success?
    end
  end
  complete = true
ensure
  File.write(File.join(root, "report.json"), {complete: complete, scenarios: scenarios, root: root}.to_pretty_json + "\n")
  puts "Saved compiler profile: #{File.join(root, "report.json")}"
end
