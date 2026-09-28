require "./cut"

dry_run = ARGV == ["--dry-run"]
unless ARGV.empty? || dry_run
  STDERR.puts("usage: scripts/release [--dry-run]")
  exit 2
end
begin
  Caramel::Cut.run(dry_run: dry_run)
rescue ex : Caramel::Cut::Refused
  STDERR.puts("scripts/release: #{ex.message}")
  exit 1
end
