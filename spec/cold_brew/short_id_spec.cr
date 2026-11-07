require "spec"
require "../../src/caramel"

describe "Caramel::ColdBrew.short_id" do
  it "writes a UUID as 25 lowercase base-36 characters, zero-padded" do
    lowest = UUID.new("00000000-0000-0000-0000-000000000000")
    Caramel::ColdBrew.short_id(lowest).should eq("0" * 25)
    highest = UUID.new("ffffffff-ffff-ffff-ffff-ffffffffffff")
    Caramel::ColdBrew.short_id(highest).should eq("f5lxx1zz5pnorynqglhzmsp33")
  end

  it "keeps every UUID to 25 characters" do
    100.times do
      Caramel::ColdBrew.short_id(SugarORM.uuid7).should match(/\A[0-9a-z]{25}\z/)
    end
  end
end
