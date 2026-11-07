require "uuid"

module SugarORM
  @@uuid7_last = 0_i64
  @@uuid7_lock = Mutex.new

  # A UUIDv7 (RFC 9562) whose 12 bits after the millisecond hold the sub-millisecond
  # fraction (method 3), so ids sort in the order they were minted. Every id is greater
  # than the last one this process minted, even when the clock stalls or steps back.
  def self.uuid7(random : Random = Random::Secure) : UUID
    ns = Time.utc.to_unix_ns
    fraction = (ns % 1_000_000) * 4096 // 1_000_000
    stamp = ((ns // 1_000_000).to_i64 << 12) | fraction.to_i64
    @@uuid7_lock.synchronize do
      stamp = @@uuid7_last + 1 if stamp <= @@uuid7_last
      @@uuid7_last = stamp
    end
    bytes = uninitialized UInt8[16]
    millis = stamp >> 12
    6.times { |index| bytes[index] = (millis >> (8 * (5 - index))).to_u8! }
    bytes[6] = ((stamp >> 8) & 0x0f).to_u8
    bytes[7] = (stamp & 0xff).to_u8
    random.random_bytes(bytes.to_slice[8, 8])
    UUID.new(bytes, variant: :rfc9562, version: :v7)
  end
end
