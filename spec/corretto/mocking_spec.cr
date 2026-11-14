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

# The fixtures type-check side by side when the first example needs
# them: `--no-codegen` builds create no program cache directory and run no
# cache cleanup, so they may overlap (CONTRIBUTING.md).
private CORRETTO_COMPILES = begin
  fixtures = %w[
    compile_mocks compile_spectator_mocks compile_valid
    compile_html_valid compile_html_invalid compile_application
    compile_property_not_method compile_property_unknown_method
    compile_property_overloaded compile_property_splat compile_property_untyped
    compile_property_unknown_type compile_property_undrawable
  ]
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

describe "Corretto HTML vocabulary" do
  it "keeps the parser out of ordinary application builds" do
    success, diagnostic = CORRETTO_COMPILES["compile_application"]
    diagnostic.should eq("")
    success.should be_true
  end

  it "compiles captured locals, loops, standard elements and explicit custom elements" do
    success, diagnostic = CORRETTO_COMPILES["compile_html_valid"]
    diagnostic.should eq("")
    success.should be_true
  end

  it "rejects a misspelled standard element at compile time" do
    success, diagnostic = CORRETTO_COMPILES["compile_html_invalid"]
    success.should be_false
    diagnostic.should contain("undefined local variable or method 'h11'")
  end
end

describe "Corretto.property's refusals" do
  it "fails the build at the property's line, with a remedy" do
    draws = "it draws Int32, Int64, Bool, String, nil, arrays, hashes and unions of them, " \
            "and any type with a class method corretto_draw(random : Random) : self"
    refusals = {
      "not_method" => "Corretto.property takes a class method, as in " \
                      "Corretto.property(Billing.share), not Billing.share(100_i64, 3)",
      "unknown_method" => "Corretto.property takes a class method, and Billing.quote is " \
                          "none: define def self.quote in Billing, each argument with its type",
      "overloaded" => "Corretto.property runs one method, and Billing.share has 2 " \
                      "overloads: give the one to run a name of its own",
      "splat" => "Corretto.property draws one value for each argument, and Billing.share " \
                 "takes a splat or a block: wrap it in a class method of typed arguments",
      "untyped" => "Corretto.property draws each argument from its type, and total of " \
                   "Billing.share has none: write total : Type in def self.share",
      "unknown_type" => "Corretto.property cannot draw total : T for Billing.share: it " \
                        "names no type the program declares; write one that is, not a " \
                        "free variable",
      "undrawable" => "Corretto.property cannot draw total : Float64 for Billing.share: " +
                      draws,
    }
    refusals.each do |name, refusal|
      success, diagnostic = CORRETTO_COMPILES["compile_property_#{name}"]
      success.should be_false
      diagnostic.should contain("Error: #{refusal}")
      diagnostic.should contain("In spec/fixtures/corretto/compile_property_#{name}.cr:")
    end
  end
end
