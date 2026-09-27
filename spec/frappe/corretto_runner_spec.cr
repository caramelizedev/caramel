require "spec"
require "file_utils"
require "../../src/frappe/corretto_runner"

private def corretto_project(&)
  root = File.tempname("caramel-corretto-")
  Dir.mkdir_p(File.join(root, "spec/requests"))
  Dir.mkdir_p(File.join(root, "spec/support"))
  begin
    yield File.realpath(root)
  ensure
    FileUtils.rm_rf(root)
  end
end

describe Caramel::Frappe::CorrettoRunner do
  it "refuses mocking APIs anywhere under spec/ with the file and line" do
    corretto_project do |root|
      File.write(File.join(root, "spec/requests/books_spec.cr"), <<-CRYSTAL)
        require "../spec_helper"
        # Never allow(Book) or mock(Book): comments are not code.
        describe "Books" do
          it "stubs" do
            allow(App::Book).to receive(:create)
            gateway = double(:gateway)
            checker = instance_double(Checker)
            Clock.stub(:now)
            fake = mock(Stripe)
            Corretto.stub_wire("https://api.stripe.com/v1/customers").to_return(status: 200, body: "{}")
            price.to_double(2)
            ledger.double(2)
            expect(Mailer).to receive(:deliver)
          end
        end
        CRYSTAL
      File.write(File.join(root, "spec/support/fakes.cr"), "Mailer = double(:mailer)\n")
      violations = Caramel::Frappe::CorrettoRunner.scan(root)
      violations.map { |violation| {violation.path, violation.line, violation.call} }.should eq([
        {"spec/requests/books_spec.cr", 5, "allow("},
        {"spec/requests/books_spec.cr", 6, "double("},
        {"spec/requests/books_spec.cr", 7, "instance_double("},
        {"spec/requests/books_spec.cr", 8, ".stub("},
        {"spec/requests/books_spec.cr", 9, "mock("},
        {"spec/requests/books_spec.cr", 13, "receive("},
        {"spec/support/fakes.cr", 1, "double("},
      ])
    end
  end

  it "finds spec files inside the project and deals them round-robin" do
    corretto_project do |root|
      %w(a b c d e).each { |name| File.write(File.join(root, "spec/requests/#{name}_spec.cr"), "") }
      File.write(File.join(root, "spec/spec_helper.cr"), "")
      files = Caramel::Frappe::CorrettoRunner.spec_files(root, ["spec"])
      files.should eq(%w(a b c d e).map { |name| "spec/requests/#{name}_spec.cr" })
      Caramel::Frappe::CorrettoRunner.spec_files(root, ["spec/requests/c_spec.cr", "spec/requests"]).size.should eq(5)
      Caramel::Frappe::CorrettoRunner.split(files, 2).should eq([
        %w(spec/requests/a_spec.cr spec/requests/c_spec.cr spec/requests/e_spec.cr),
        %w(spec/requests/b_spec.cr spec/requests/d_spec.cr),
      ])
      Caramel::Frappe::CorrettoRunner.split(files[0, 2], 8).size.should eq(2)
      expect_raises(Caramel::Frappe::Error, "inside the project") { Caramel::Frappe::CorrettoRunner.spec_files(root, ["../"]) }
      expect_raises(Caramel::Frappe::Error, "No spec file") { Caramel::Frappe::CorrettoRunner.spec_files(root, ["spec/missing_spec.cr"]) }
      expect_raises(Caramel::Frappe::Error, "No *_spec.cr files") { Caramel::Frappe::CorrettoRunner.spec_files(root, ["spec/support"]) }
    end
  end

  it "accepts spec paths and one --concurrency within the Latte worker limit" do
    Caramel::Frappe::CorrettoRunner.arguments([] of String).should eq({["spec"], 1})
    Caramel::Frappe::CorrettoRunner.arguments(["spec/models", "--concurrency=8"]).should eq({["spec/models"], 8})
    [["--concurrency=0"], ["--concurrency=9"], ["--concurrency=two"], ["--concurrency=2", "--concurrency=3"], ["--tag", "fast"], [""]].each do |args|
      Caramel::Frappe::CorrettoRunner.arguments(args).should be_nil
    end
  end
end
