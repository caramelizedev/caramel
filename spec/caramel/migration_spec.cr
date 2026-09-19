require "spec"
require "../../src/caramel/migration"

describe Caramel::Migration do
  it "rejects blank statements before a migration can be journaled" do
    ["", " \n "].each do |sql|
      expect_raises(ArgumentError) { Caramel::Migration.new(1_i64, "Empty", [sql]) }
    end
  end
end
