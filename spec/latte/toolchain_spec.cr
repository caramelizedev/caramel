require "spec"
require "file_utils"
require "../../src/latte/toolchain"

private def with_checkout(& : String, String ->) : Nil
  base = File.tempname("caramel-toolchain-spec-", dir: "/private/tmp")
  Dir.mkdir(base, 0o700)
  checkout = File.join(base, "caramel")
  root = File.join(base, "toolchain")
  Dir.mkdir(checkout, 0o700)
  Dir.mkdir(root, 0o700)
  begin
    yield checkout, root
  ensure
    FileUtils.rm_rf(base)
  end
end

private def point(checkout : String, target : String, mode : Int32 = 0o644) : String
  pointer = File.join(checkout, ".caramel-toolchain")
  File.write(pointer, target + "\n")
  File.chmod(pointer, mode)
  pointer
end

describe Caramel::Latte::Toolchain do
  it "prefers CARAMEL_TOOLCHAIN_ROOT, then the checkout's .caramel-toolchain" do
    with_checkout do |checkout, root|
      none = {} of String => String
      pointed = {root, ".caramel-toolchain"}
      Caramel::Latte::Toolchain.locate(checkout, none).should be_nil
      point(checkout, root)
      Caramel::Latte::Toolchain.locate(checkout, none).should eq(pointed)
      override = {"CARAMEL_TOOLCHAIN_ROOT" => "/elsewhere"}
      elsewhere = {"/elsewhere", "CARAMEL_TOOLCHAIN_ROOT"}
      Caramel::Latte::Toolchain.locate(checkout, override).should eq(elsewhere)
      empty_override = {"CARAMEL_TOOLCHAIN_ROOT" => ""}
      Caramel::Latte::Toolchain.locate(checkout, empty_override).should eq(pointed)
      installed = File.realpath(root)
      Caramel::Latte::Toolchain.for_checkout(checkout, none).root.should eq(installed)
    end
  end

  it "names the fix when a checkout has no toolchain" do
    with_checkout do |checkout, _|
      fix = "No Caramel toolchain is installed for #{checkout}. " \
            "Run scripts/install-toolchain."
      expect_raises(Caramel::Latte::Toolchain::Unavailable, fix) do
        Caramel::Latte::Toolchain.for_checkout(checkout, {} of String => String)
      end
    end
  end

  it "refuses a pointer that someone else could redirect" do
    with_checkout do |checkout, root|
      unsafe = "must be a regular file you own that no one else can write"
      point(checkout, root, 0o666)
      expect_raises(Caramel::Latte::Toolchain::Unavailable, unsafe) do
        Caramel::Latte::Toolchain.locate(checkout, {} of String => String)
      end
      File.delete(File.join(checkout, ".caramel-toolchain"))
      real = point(File.dirname(root), root)
      File.symlink(real, File.join(checkout, ".caramel-toolchain"))
      expect_raises(Caramel::Latte::Toolchain::Unavailable, unsafe) do
        Caramel::Latte::Toolchain.locate(checkout, {} of String => String)
      end
    end
  end

  it "refuses a pointer to a relative path" do
    with_checkout do |checkout, _|
      point(checkout, "toolchains/dev")
      relative = "must name an absolute toolchain directory"
      expect_raises(Caramel::Latte::Toolchain::Unavailable, relative) do
        Caramel::Latte::Toolchain.locate(checkout, {} of String => String)
      end
    end
  end
end
