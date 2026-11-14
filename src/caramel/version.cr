module Caramel
  # The release version. shard.yml is its only source (ADR 0016); this reads
  # it when the framework compiles, from a checkout or an app's lib/caramel.
  VERSION = {{
              read_file("#{__DIR__}/../../shard.yml")
                .lines.find(&.starts_with?("version:"))
                .split(":")[1].strip
            }}

  # Each release is the tag v<VERSION> here, with its documentation.
  REPOSITORY = "https://github.com/caramelizedev/caramel"

  # The guides, one edition per release at /docs/<VERSION>/ (the editions rule of ADR 0014).
  WEBSITE = "https://caramelize.dev"
end
