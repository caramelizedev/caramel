# RFC-0008 §2.3: quantities read as what they measure. Crystal already turns
# integers into spans (`48.hours`) and spans into times (`3.days.from_now`);
# Caramel adds sizes in bytes and midnight, so a limit reads
# `storage_used > 50.gigabytes` and a schedule `3.days.from_now.at_midnight`.
#
# Sizes are `Int64` byte counts in binary multiples, as `Int#humanize_bytes`
# counts them: a kilobyte is 1024 bytes. A size past `Int64::MAX` raises
# `OverflowError`.
struct Int
  # Returns `self` kilobytes (1024 bytes each) as a byte count.
  def kilobytes : Int64
    to_i64 * 1024
  end

  # :ditto:
  def kilobyte : Int64
    kilobytes
  end

  # Returns `self` megabytes (1024 kilobytes each) as a byte count.
  def megabytes : Int64
    kilobytes * 1024
  end

  # :ditto:
  def megabyte : Int64
    megabytes
  end

  # Returns `self` gigabytes (1024 megabytes each) as a byte count.
  def gigabytes : Int64
    megabytes * 1024
  end

  # :ditto:
  def gigabyte : Int64
    gigabytes
  end

  # Returns `self` terabytes (1024 gigabytes each) as a byte count.
  def terabytes : Int64
    gigabytes * 1024
  end

  # :ditto:
  def terabyte : Int64
    terabytes
  end
end

struct Time
  # Returns midnight at the start of this time's day, in its own location,
  # as `#at_beginning_of_day` does: `3.days.from_now.at_midnight`.
  def at_midnight : Time
    at_beginning_of_day
  end
end
