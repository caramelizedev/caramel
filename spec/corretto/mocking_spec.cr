require "spec"

private CORRETTO_REPO = File.expand_path("../..", __DIR__)

private def corretto_compile(fixture : String) : {Bool, String}
  error = IO::Memory.new
  crystal = File.join(CORRETTO_REPO, "scripts/crystal")
  arguments = ["build", "--no-codegen", "spec/fixtures/corretto/#{fixture}.cr"]
  status = Process.run(
    crystal,
    arguments,
    chdir: CORRETTO_REPO,
    output: Process::Redirect::Close,
    error: error,
  )
  {status.success?, error.to_s}
end

# The three fixtures type-check side by side when the first example needs
# them: `--no-codegen` builds create no program cache directory and run no
# cache cleanup, so they may overlap (CONTRIBUTING.md).
private CORRETTO_COMPILES = begin
  fixtures = %w[compile_mocks compile_spectator_mocks compile_valid]
  compiled = Channel({String, Bool, String}).new(fixtures.size)
  fixtures.each do |fixture|
    spawn do
      success, diagnostic = corretto_compile(fixture)
      compiled.send({fixture, success, diagnostic})
    rescue ex
      compiled.send({fixture, false, "could not run the compiler: #{ex.message}"})
    end
  end
  results = Array.new(fixtures.size) { compiled.receive }
  results.to_h { |(fixture, success, diagnostic)| {fixture, {success, diagnostic}} }
end

describe "Corretto's mocking refusal" do
  it "fails the build, with a remedy, when a mocking library is loaded before or after Corretto" do
    refusals = {
      "compile_mocks"           => "`Mocks` from a mocking library is loaded",
      "compile_spectator_mocks" => "Spectator::Mocks is loaded",
    }
    refusals.each do |fixture, reason|
      success, diagnostic = CORRETTO_COMPILES[fixture]
      success.should be_false
      diagnostic.should contain("Corretto forbids mocking")
      diagnostic.should contain(reason)
      diagnostic.should contain("Remediation: remove")
    end
  end

  it "accepts application types that merely share a mocking library's constant names" do
    success, diagnostic = CORRETTO_COMPILES["compile_valid"]
    diagnostic.should eq("")
    success.should be_true
  end
end
