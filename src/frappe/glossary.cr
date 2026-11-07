require "json"
require "./dev_files"
require "./tools"

module Caramel::Frappe
  # `frappe glossary` and `frappe contexts`: the detailed glossary and the context map the
  # application's `glossary` command prints as JSON (ADR 0059). The document is kept in
  # `.caramel/glossary.json` with the source signature it was read from, so an unchanged
  # application answers without a build.
  class Glossary
    getter document : JSON::Any

    def initialize(@document : JSON::Any)
    end

    # The application's glossary, from the cache when the source is unchanged.
    def self.load(project : Project, tools : Tools) : Glossary
      cache = File.join(project.root, ".caramel/glossary.json")
      source = signature(project)
      if source && (cached = cached(cache, source))
        return new(cached)
      end
      binary = tools.compile(project)
      errors = IO::Memory.new
      development = {"CARAMEL_ENV" => "development"}
      status, printed = tools.capture(binary, ["glossary"], project.root, development, errors)
      if status.exit_code == 2 && errors.to_s.starts_with?("Usage:")
        raise Error.new("This application has no glossary: it does not require " \
                        "caramel/sweet_talk")
      end
      unless status.success?
        raise Error.new("The application's glossary command failed: #{errors.to_s.strip}")
      end
      document = JSON.parse(printed)
      store(project, cache, source, document) if source
      new(document)
    end

    private def self.signature(project : Project) : String?
      DevFiles.new(project.root).snapshot.source
    rescue Error
      nil
    end

    private def self.cached(cache : String, source : String) : JSON::Any?
      return if File.symlink?(cache) || !File.file?(cache)
      kept = JSON.parse(File.read(cache))
      kept["glossary"]? if kept["source"]?.try(&.as_s?) == source
    rescue JSON::ParseException
      nil
    end

    private def self.store(project : Project, cache : String, source : String,
                           document : JSON::Any) : Nil
      Latte::StateSecurity.ensure_owned_directory(File.join(project.root, ".caramel"))
      File.delete?(cache) if File.symlink?(cache)
      File.write(cache, {source: source, glossary: document}.to_json)
    end

    # The glossary as Markdown: one section per context or kernel, its meaning, its
    # follows: and shares:, then a table of its terms with their facts.
    def to_markdown : String
      String.build do |io|
        io << "# Glossary\n"
        sections.each do |name, terms|
          head = terms.find { |term| {"context", "kernel"}.includes?(term["kind"].as_s) }
          io << "\n## " << (name.empty? ? "Outside any context" : name)
          if head
            subdomain = head["subdomain"].as_s?
            io << " (" << head["kind"].as_s << (subdomain ? ", #{subdomain}" : "") << ")"
            io << "\n\n" << head["means"].as_s << "\n"
            facts = facts_text(head["facts"])
            io << "\n" << facts << "\n" unless facts.empty?
          else
            io << "\n"
          end
          rows = head ? terms.reject { |term| term == head } : terms
          next if rows.empty?
          io << "\n| Term | Kind | Means | Facts |\n| --- | --- | --- | --- |\n"
          rows.each do |term|
            io << "| " << cell(term["name"].as_s) << " | " << term["kind"].as_s << " | "
            io << cell(term["means"].as_s) << " | " << cell(facts_text(term["facts"])) << " |\n"
          end
        end
      end
    end

    # The context map as text: each context and kernel with the edges that leave it.
    def to_text : String
      String.build do |io|
        modules.each do |name|
          io << name << "\n"
          edges.select { |edge| edge[0] == name }.each do |edge|
            io << "  " << VERBS[edge[2]] << " " << edge[1] << "\n"
          end
        end
      end
    end

    # The context map as a Mermaid flowchart: a dependency is an arrow, an event a dotted
    # arrow, a shared kernel a line and an outside system a hexagon.
    def to_mermaid : String
      String.build do |io|
        io << "flowchart LR\n"
        modules.each { |name| io << "  " << name << "\n" }
        edges.each do |(from, to, kind)|
          case kind
          when "dependency" then io << "  " << from << " -->|depends on| " << to << "\n"
          when "event"      then io << "  " << from << " -.->|reacts to| " << to << "\n"
          when "kernel"     then io << "  " << from << " ---|shares| " << to << "\n"
          else
            io << "  " << from << " -->|calls| " << to << "{{" << to << "}}\n"
          end
        end
      end
    end

    VERBS = {
      "dependency" => "depends on", "event" => "reacts to",
      "kernel" => "shares", "outside" => "calls",
    }

    private def terms : Array(JSON::Any)
      @document["terms"].as_a
    end

    private def edges : Array({String, String, String})
      @document["map"].as_a.map { |edge| {edge[0].as_s, edge[1].as_s, edge[2].as_s} }
    end

    private def modules : Array(String)
      terms.select { |term| {"context", "kernel"}.includes?(term["kind"].as_s) }
        .map(&.["name"].as_s)
    end

    private def sections : Array({String, Array(JSON::Any)})
      grouped = {} of String => Array(JSON::Any)
      terms.each { |term| (grouped[term["context"].as_s] ||= [] of JSON::Any) << term }
      grouped.to_a
    end

    private def facts_text(facts : JSON::Any) : String
      facts.as_h.compact_map do |name, values|
        listed = values.as_a.map(&.as_s)
        next if listed.empty?
        "#{name}: #{listed.join(", ")}"
      end.join("; ")
    end

    private def cell(text : String) : String
      text.gsub('|', "\\|").gsub('\n', ' ')
    end
  end
end
