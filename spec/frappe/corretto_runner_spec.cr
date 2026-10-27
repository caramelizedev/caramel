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
            Corretto.stub_wire("https://api.stripe.com/v1/customers")\
            .to_return(status: 200, body: "{}")
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

  it "reads .env.test for the app's test settings, refusing keys Corretto owns" do
    corretto_project do |root|
      settings = File.join(root, ".env.test")
      read = -> { Caramel::Frappe::CorrettoRunner.test_environment(root) }
      read.call.should be_empty

      File.write(settings, <<-ENV)
        # Test-only values
        WEBHOOK_SECRET=test-webhook-secret
        DELIVERY_TARGET="https://receiver.example/hooks"
        ENV
      read.call.should eq({
        "WEBHOOK_SECRET"  => "test-webhook-secret",
        "DELIVERY_TARGET" => "https://receiver.example/hooks",
      })

      File.write(settings, <<-ENV)
        APP_SECRET=x
        SPEC_DATABASE_URL=y
        CRYSTAL_OPTS=z
        WEBHOOK_SECRET=ok
        ENV
      owned = ".env.test cannot set APP_SECRET, SPEC_DATABASE_URL, CRYSTAL_OPTS"
      expect_raises(Caramel::Frappe::Error, owned) { read.call }

      File.delete(settings)
      elsewhere = File.join(root, "elsewhere.env")
      File.write(elsewhere, "WEBHOOK_SECRET=x\n")
      File.symlink(elsewhere, settings)
      expect_raises(Caramel::Frappe::Error, "regular file") { read.call }
    end
  end

  it "finds spec files inside the project and deals them round-robin" do
    corretto_project do |root|
      %w[a b c d e].each { |name| File.write(File.join(root, "spec/requests/#{name}_spec.cr"), "") }
      File.write(File.join(root, "spec/spec_helper.cr"), "")
      files = Caramel::Frappe::CorrettoRunner.spec_files(root, ["spec"])
      files.should eq(%w[a b c d e].map { |name| "spec/requests/#{name}_spec.cr" })
      overlapping = ["spec/requests/c_spec.cr", "spec/requests"]
      Caramel::Frappe::CorrettoRunner.spec_files(root, overlapping).size.should eq(5)
      Caramel::Frappe::CorrettoRunner.split(files, 2).should eq([
        %w[spec/requests/a_spec.cr spec/requests/c_spec.cr spec/requests/e_spec.cr],
        %w[spec/requests/b_spec.cr spec/requests/d_spec.cr],
      ])
      Caramel::Frappe::CorrettoRunner.split(files[0, 2], 8).size.should eq(2)
      expect_raises(Caramel::Frappe::Error, "inside the project") do
        Caramel::Frappe::CorrettoRunner.spec_files(root, ["../"])
      end
      expect_raises(Caramel::Frappe::Error, "No spec file") do
        Caramel::Frappe::CorrettoRunner.spec_files(root, ["spec/missing_spec.cr"])
      end
      expect_raises(Caramel::Frappe::Error, "No *_spec.cr files") do
        Caramel::Frappe::CorrettoRunner.spec_files(root, ["spec/support"])
      end
    end
  end

  it "formats durations as tenths of a second under a minute, else m:ss" do
    format = ->(span : Time::Span) { Caramel::Frappe::CorrettoRunner.format_duration(span) }
    format.call(Time::Span.zero).should eq("0.0s")
    format.call(4.2.seconds).should eq("4.2s")
    format.call(59.94.seconds).should eq("59.9s")
    format.call(59.95.seconds).should eq("1:00")
    format.call(61.4.seconds).should eq("1:01")
    format.call(200.seconds).should eq("3:20")
    format.call(3661.seconds).should eq("61:01")
  end

  it "relays complete lines at once and an unfinished line after it stays quiet" do
    reader, writer = IO.pipe
    log = IO::Memory.new
    quiet = 50.milliseconds
    done = Channel(Nil).new
    spawn do
      Caramel::Frappe::CorrettoRunner.relay(reader, log, "[w1] ", quiet)
      done.send(nil)
    end
    writer << "1 examples\n.."
    writer.flush
    sleep 10.milliseconds
    log.to_s.should eq("[w1] 1 examples\n")
    sleep quiet * 4
    log.to_s.should eq("[w1] 1 examples\n[w1] ..\n")
    writer << ". done\n"
    writer.flush
    sleep 10.milliseconds
    log.to_s.should eq("[w1] 1 examples\n[w1] ..\n[w1] . done\n")
    writer << "tail"
    writer.close
    done.receive
    log.to_s.should eq("[w1] 1 examples\n[w1] ..\n[w1] . done\n[w1] tail\n")
  end

  it "forwards a steady trickle without newlines once per quiet interval" do
    reader, writer = IO.pipe
    log = IO::Memory.new
    done = Channel(Nil).new
    spawn do
      Caramel::Frappe::CorrettoRunner.relay(reader, log, "[w2] ", 50.milliseconds)
      done.send(nil)
    end
    40.times do
      writer << '.'
      writer.flush
      sleep 5.milliseconds
    end
    writer.close
    done.receive
    lines = log.to_s.lines
    lines.size.should be >= 3
    lines.size.should be <= 6
    lines.all?(&.starts_with?("[w2] .")).should be_true
    lines.join.count('.').should eq(40)
  end
end
