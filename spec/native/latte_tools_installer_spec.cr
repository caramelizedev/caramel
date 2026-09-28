require "spec"
require "compress/gzip"
require "../../scripts/checks/support/harness"

COREDNS_TEST_BINARY = File.join(Caramel::Checks::REPO, "bin/test/install-latte-tools")
raise "Run scripts/check native" unless File.file?(COREDNS_TEST_BINARY)

private def tar_field(header : Bytes, offset : Int32, length : Int32, text : String) : Nil
  raise "ustar field overflow" if text.bytesize > length
  header[offset, text.bytesize].copy_from(text.to_slice)
end

private def write_coredns_archive(path : String, member : String, payload : String) : Nil
  header = Bytes.new(512, 0_u8)
  tar_field(header, 0, 100, member)
  tar_field(header, 100, 8, "%07o\0" % 0o755)
  tar_field(header, 108, 8, "%07o\0" % 0)
  tar_field(header, 116, 8, "%07o\0" % 0)
  tar_field(header, 124, 12, "%011o\0" % payload.bytesize)
  tar_field(header, 136, 12, "%011o\0" % 0)
  header[148, 8].fill(' '.ord.to_u8)
  header[156] = '0'.ord.to_u8
  tar_field(header, 257, 6, "ustar\0")
  tar_field(header, 263, 2, "00")
  checksum = header.sum(&.to_i)
  tar_field(header, 148, 8, "%06o\0 " % checksum)
  Compress::Gzip::Writer.open(path) do |gzip|
    gzip.write(header)
    gzip.write(payload.to_slice)
    padding = (512 - payload.bytesize % 512) % 512
    gzip.write(Bytes.new(padding, 0_u8))
    gzip.write(Bytes.new(1024, 0_u8))
  end
end

private def with_coredns_fixture(member : String = "coredns", binary_digest : String? = nil, &)
  root = Caramel::Checks.private_temp("Toolchain With Spaces-")
  archive = File.join(root, "test.tgz")
  manifest = File.join(root, "fixture.json")
  payload = "verified executable"
  write_coredns_archive(archive, member, payload)
  File.write(manifest, {"coredns" => {
    "version"        => "1.14.7",
    "url"            => "https://example.invalid/coredns.tgz",
    "archive_sha256" => Digest::SHA256.new.file(archive).hexfinal,
    "binary_sha256"  => binary_digest || Digest::SHA256.hexdigest(payload),
  }}.to_json)
  begin
    yield root, archive, manifest
  ensure
    FileUtils.rm_rf(root)
  end
end

private def run_coredns(root : String, archive : String, manifest : String)
  Caramel::Checks.run([COREDNS_TEST_BINARY, "--archive", archive], env: {
    "CARAMEL_TOOLCHAIN_ROOT"    => root,
    "CARAMEL_INSTALLER_FIXTURE" => manifest,
  })
end

private def coredns_target(root : String) : String
  File.join(root, "data", "installs", "github-coredns-coredns", "1.14.7")
end

describe "native CoreDNS installer" do
  it "installs a verified archive privately and repeats without rewriting it" do
    with_coredns_fixture do |root, archive, manifest|
      first = run_coredns(root, archive, manifest)
      first.success?.should be_true
      target = coredns_target(root)
      binary = File.join(target, "coredns")
      first.stdout.should contain("Verified CoreDNS 1.14.7: #{binary}")
      File.read(binary).should eq("verified executable")
      File.info(target).permissions.value.should eq(0o700)
      File.info(binary).permissions.value.should eq(0o755)
      File.info(File.join(target, "receipt.json")).permissions.value.should eq(0o600)
      receipt = File.read(File.join(target, "receipt.json"))
      JSON.parse(receipt)["binary_sha256"].as_s.should eq(Digest::SHA256.hexdigest("verified executable"))
      File.delete(archive)
      second = run_coredns(root, archive, manifest)
      second.success?.should be_true
      File.read(File.join(target, "receipt.json")).should eq(receipt)
    end
  end

  it "preserves a modified installed executable" do
    with_coredns_fixture do |root, archive, manifest|
      run_coredns(root, archive, manifest).success?.should be_true
      binary = File.join(coredns_target(root), "coredns")
      File.write(binary, "tampered")
      result = run_coredns(root, archive, manifest)
      result.success?.should be_false
      result.stderr.should contain("existing CoreDNS installation failed verification; preserved for inspection")
      File.read(binary).should eq("tampered")
    end
  end

  it "leaves no target after a binary checksum mismatch" do
    with_coredns_fixture(binary_digest: "0" * 64) do |root, archive, manifest|
      result = run_coredns(root, archive, manifest)
      result.success?.should be_false
      result.stderr.should contain("CoreDNS binary checksum failed; installation was not changed")
      File.exists?(coredns_target(root)).should be_false
      children = Dir.children(File.dirname(coredns_target(root)))
      children.should be_empty
    end
  end

  it "rejects traversal archive members and symlinked destinations" do
    with_coredns_fixture(member: "../coredns") do |root, archive, manifest|
      result = run_coredns(root, archive, manifest)
      result.success?.should be_false
      result.stderr.should contain("unexpected CoreDNS archive contents")
      target = coredns_target(root)
      Dir.mkdir(File.join(root, "real"), 0o700)
      File.symlink(File.join(root, "real"), target)
      result = run_coredns(root, archive, manifest)
      result.success?.should be_false
      result.stderr.should contain("tool destination must not be a symlink")
      Dir.children(File.join(root, "real")).should be_empty
    end
  end
end
