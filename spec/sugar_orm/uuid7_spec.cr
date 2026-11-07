require "spec"
require "../../src/sugar_orm"

private def stamp(id : UUID) : Time
  millis = id.bytes.to_slice[0, 6].reduce(0_i64) { |total, byte| (total << 8) | byte }
  Time.unix_ms(millis)
end

describe "SugarORM.uuid7" do
  it "mints ids that each sort after the last, even within one millisecond" do
    ids = Array.new(10_000) { SugarORM.uuid7 }
    ids.each_cons_pair { |earlier, later| earlier.hexstring.should be < later.hexstring }
  end

  it "mints RFC 9562 version 7 ids stamped with the current millisecond" do
    id = SugarORM.uuid7
    id.version.should eq(UUID::Version::V7)
    id.variant.should eq(UUID::Variant::RFC9562)
    (stamp(id) - Time.utc).abs.should be < 1.second
  end
end
