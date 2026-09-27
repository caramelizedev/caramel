require "spec"

private CORRETTO_REPO = File.expand_path("../..", __DIR__)

private def corretto_compile(fixture : String) : {Bool, String}
  error = IO::Memory.new
  status = Process.run(File.join(CORRETTO_REPO, "scripts/crystal"), ["build", "--no-codegen", "spec/fixtures/corretto/#{fixture}.cr"],
    chdir: CORRETTO_REPO, output: Process::Redirect::Close, error: error)
  {status.success?, error.to_s}
end

describe "Corretto's mocking refusal" do
  it "fails the build, with a remedy, when a mocking library is loaded before or after Corretto" do
    {"compile_mocks" => "`Mocks` from a mocking library is loaded", "compile_spectator_mocks" => "Spectator::Mocks is loaded"}.each do |fixture, reason|
      success, diagnostic = corretto_compile(fixture)
      success.should be_false
      diagnostic.should contain("Corretto forbids mocking")
      diagnostic.should contain(reason)
      diagnostic.should contain("Remediation: remove")
    end
  end

  it "accepts application types that merely share a mocking library's constant names" do
    success, diagnostic = corretto_compile("compile_valid")
    diagnostic.should eq("")
    success.should be_true
  end
end
