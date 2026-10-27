# SweetTalk's calendar day, `value Day, Date`: a real day that refuses the calendar's gaps, is
# a SugarORM::Date underneath, moves and compares by days, is kept in a `date` column that
# PostgreSQL orders as a day, and may be optional, a part of a value, or a field of an entity.
require "./support/app"

module CalendarDaysSpec
  alias Lending = Library::Lending

  def self.day(text : String) : Lending::Day
    Lending::Day.new(text)
  end

  def self.loan(on : String = "2026-03-01", reader : String = "Ada") : Lending::Loan
    Lending::Loan.create(reader: reader, borrowed_on: day(on))
  end

  def self.term(left : String, due : String) : Lending::Term
    Lending::Term.new(left_on: day(left), due_on: day(due))
  end

  # The column type PostgreSQL holds for *table*'s *column*.
  def self.column_type(table : String, column : String) : String
    query = <<-SQL
      SELECT format_type(a.atttypid, a.atttypmod) AS held
      FROM pg_attribute a JOIN pg_class c ON c.oid = a.attrelid
      WHERE c.relname = '#{table}' AND a.attname = '#{column}'
      SQL
    SugarORM.sql(query, as: {held: String}).first[:held]
  end

  # Runs *sql* in its own savepoint and returns the check it broke.
  def self.broken(sql : String, *args) : String?
    SugarORM::Repo.transaction { SugarORM.sql_exec(sql, *args) }
    nil
  rescue error : SugarORM::CheckViolation
    error.constraint
  end
end

describe "SweetTalk's calendar days" do
  it "accepts a real day and refuses one the calendar lacks" do
    CalendarDaysSpec.day("2028-02-29").to_s.should eq("2028-02-29")
    ["2026-02-30", "2026-13-01", "2027-02-29", "0000-01-01", "2026-3-1", "2026-03-01 ", "",
     "tomorrow", "２０２６-03-01"].each do |text|
      expect_raises(SweetTalk::Refusal,
        "Day must be a calendar day written YYYY-MM-DD, as in 2026-02-28") do
        Library::Lending::Day.new(text)
      end
    end
  end

  it "is a SugarORM::Date underneath" do
    day = CalendarDaysSpec.day("2026-03-01")
    day.raw.should eq(SugarORM::Date.new(2026, 3, 1))
    day.raw.should be_a(SugarORM::Date)
    Library::Lending::Day.new(SugarORM::Date.new(2026, 3, 1)).should eq(day)
    Library::Lending::Day::SWEETTALK_WRAPS.should eq("::SugarORM::Date")
    Library::Lending::Day::SWEETTALK_CODEC.should eq("::SugarORM::DateCodec")
  end

  it "reads its parts, builds from them, and reads a time's own calendar day" do
    day = CalendarDaysSpec.day("2026-12-31")
    {day.year, day.month, day.day}.should eq({2026, 12, 31})
    Library::Lending::Day.new(2027, 1, 5).to_s.should eq("2027-01-05")
    Library::Lending::Day.new(2027_i64, 1_u8, 5_i16).to_s.should eq("2027-01-05")
    early = Time.local(2026, 3, 1, 1, 0, 0, location: Time::Location.fixed(5 * 3600))
    early.to_utc.day.should eq(28)
    Library::Lending::Day.of(early).should eq(Library::Lending::Day.new(2026, 3, 1))
    late = Time.local(2026, 3, 1, 23, 30, 0, location: Time::Location.fixed(-8 * 3600))
    late.to_utc.day.should eq(2)
    Library::Lending::Day.of(late).to_s.should eq("2026-03-01")
    day.to_time.should eq(Time.utc(2026, 12, 31))
  end

  it "has no word for today, which would read the clock and its zone" do
    Library::Lending::Day.responds_to?(:today).should be_false
  end

  it "moves by days, counts the days between two, and refuses what leaves the calendar" do
    day = CalendarDaysSpec.day("2026-12-31")
    (day + 1).to_s.should eq("2027-01-01")
    (day + 7).to_s.should eq("2027-01-07")
    (day - 365).to_s.should eq("2025-12-31")
    (day + 0).should eq(day)
    (CalendarDaysSpec.day("2028-03-01") - CalendarDaysSpec.day("2028-02-01")).should eq(29)
    (CalendarDaysSpec.day("2026-01-01") - CalendarDaysSpec.day("2026-01-10")).should eq(-9)
    message = "Day must be a calendar day"
    expect_raises(SweetTalk::Refusal, message) { CalendarDaysSpec.day("9999-12-31") + 1 }
    expect_raises(SweetTalk::Refusal, message) { CalendarDaysSpec.day("0001-01-01") - 1 }
    expect_raises(SweetTalk::Refusal, message) { day + Int64::MAX }
    expect_raises(SweetTalk::Refusal, message) { day - Int64::MIN }
    expect_raises(SweetTalk::Refusal, message) { day + UInt64::MAX }
    expect_raises(SweetTalk::Refusal, message) { Library::Lending::Day.new(2026, 2, 30) }
    expect_raises(SweetTalk::Refusal, message) { Library::Lending::Day.new(2026, 13, 1) }
    expect_raises(SweetTalk::Refusal, message) { Library::Lending::Day.new(2026_i64 << 40, 1, 1) }
  end

  it "compares and sorts as a day" do
    days = %w[2026-03-01 2025-12-31 2026-02-28 2026-02-01].map { |text| CalendarDaysSpec.day(text) }
    days.sort.map(&.to_s).should eq(%w[2025-12-31 2026-02-01 2026-02-28 2026-03-01])
    (days[1] < days[0]).should be_true
    days.max.to_s.should eq("2026-03-01")
    days.min_by(&.raw).to_s.should eq("2025-12-31")
    days.to_set.size.should eq(4)
  end

  it "is kept in a date column, which PostgreSQL holds as a day" do
    SweetTalkSpec.rolled_back do
      loan = CalendarDaysSpec.loan("2026-03-01")
      CalendarDaysSpec.column_type("lending_loans", "borrowed_on").should eq("date")
      CalendarDaysSpec.column_type("lending_loans", "returned_on").should eq("date")
      CalendarDaysSpec.column_type("lending_loan_fines", "charged_on").should eq("date")
      stored = SugarORM.sql("SELECT borrowed_on::text AS day FROM lending_loans",
        as: {day: String}).first[:day]
      stored.should eq("2026-03-01")
      Library::Lending::Loan.find(loan.id).borrowed_on.should eq(CalendarDaysSpec.day("2026-03-01"))
    end
  end

  it "refuses around the domain a text that is not a day, by the column's type" do
    SweetTalkSpec.rolled_back do
      loan = CalendarDaysSpec.loan
      expect_raises(PQ::PQError, /out of range|invalid input syntax/) do
        SugarORM::Repo.transaction do
          SugarORM.sql_exec("UPDATE lending_loans SET borrowed_on = '2026-02-30' WHERE id = $1",
            loan.id.raw)
        end
      end
    end
  end

  it "stores an optional day as null, and a day once it is given" do
    SweetTalkSpec.rolled_back do
      loan = CalendarDaysSpec.loan
      loan.returned_on.should be_nil
      Library::Lending::Loan.find(loan.id).returned_on.should be_nil
      loan.give_back(CalendarDaysSpec.day("2026-03-09"))
      Library::Lending::Loan.find(loan.id).returned_on.should eq(CalendarDaysSpec.day("2026-03-09"))
      expect_raises(SweetTalk::Refusal, "A book cannot come back before it left.") do
        CalendarDaysSpec.loan("2026-03-10").give_back(CalendarDaysSpec.day("2026-03-09"))
      end
    end
  end

  it "keeps a day in an entity, optional and not" do
    SweetTalkSpec.rolled_back do
      loan = CalendarDaysSpec.loan
      loan.charge(CalendarDaysSpec.day("2026-03-12"), nil)
      loan.charge(CalendarDaysSpec.day("2026-03-15"), CalendarDaysSpec.day("2026-03-16"))
      fines = Library::Lending::Loan.find(loan.id).fines
      fines.map(&.charged_on.to_s).should eq(%w[2026-03-12 2026-03-15])
      fines.map(&.waived_on.try(&.to_s)).should eq([nil, "2026-03-16"])
    end
  end

  it "keeps a day as a part of a value, one date column for each, and an optional value" do
    SweetTalkSpec.rolled_back do
      loan = CalendarDaysSpec.loan
      CalendarDaysSpec.column_type("lending_loans", "term_left_on").should eq("date")
      CalendarDaysSpec.column_type("lending_loans", "term_due_on").should eq("date")
      Library::Lending::Loan.find(loan.id).term.should be_nil
      loan.set_term(CalendarDaysSpec.term("2026-03-01", "2026-03-22"))
      term = Library::Lending::Loan.find(loan.id).term.not_nil!
      {term.left_on.to_s, term.due_on.to_s}.should eq({"2026-03-01", "2026-03-22"})
      expect_raises(SweetTalk::Refusal, "a book is due before it left") do
        CalendarDaysSpec.term("2026-03-22", "2026-03-01")
      end
      loan.set_term(nil)
      Library::Lending::Loan.find(loan.id).term.should be_nil
      check = CalendarDaysSpec.broken(
        "UPDATE lending_loans SET term_due_on = '2026-03-22' WHERE id = $1", loan.id.raw)
      check.to_s.should start_with("check_lending_loans_term_all_or_none_")
    end
  end

  it "needs no migration once its table exists, and derives the checked retype of a text column" do
    declared = SugarORM::Catalog.declared
    snapshot = SugarORM::Introspection.read(SweetTalkSpec.owner)
    clean = SugarORM::Differ.diff(declared, snapshot)
    (clean.transactional + clean.online).should be_empty
    clean.halts.should be_empty
    text = snapshot.tables.map do |table|
      next table unless table.name == "lending_loans"
      columns = table.columns.map do |column|
        next column unless column.name == "borrowed_on"
        SugarORM::Catalog::Column.new(column.name, "text", column.nullable, column.default)
      end
      SugarORM::Catalog::Table.new(table.name, columns, table.indexes, table.foreign_keys,
        table.drops, table.checks)
    end
    plan = SugarORM::Differ.diff(declared, text)
    plan.halts.should be_empty
    statements = SugarORM::DDL.statements(plan.transactional)
    statements.size.should eq(2)
    statements[0].should start_with("DO $caramel$\n")
    statements[1].should eq(
      %(-- caramel:allow alter-column-type lending_loans.borrowed_on\n) +
      %(ALTER TABLE "lending_loans" ALTER COLUMN "borrowed_on" TYPE date USING "borrowed_on"::date))
  end
end

module CalendarDaysSpec
  # One loan for each day, made in that order, as the days of one ledger.
  def self.loans(*days : String) : Array(Lending::Loan)
    days.map { |text| loan(text) }.to_a
  end

  def self.ids(loans : Array(Lending::Loan)) : Array(Lending::Loan::Id)
    loans.map(&.id)
  end

  # Checks that *rule* picks the loans at *positions* of *loans*, asked of PostgreSQL by
  # `all(satisfying:)` and of each aggregate in *everything* by `satisfied_by?`.
  def self.agree(rule : T.class, everything : Array(Lending::Loan),
                 loans : Array(Lending::Loan), positions : Array(Int32)) : Nil forall T
    expected = positions.map { |position| loans[position].id.raw }.sort!
    Lending::Loan.all(satisfying: rule).map(&.id.raw).sort!.should eq(expected)
    everything.select { |loan| rule.satisfied_by?(loan) }.map(&.id.raw).sort!.should eq(expected)
  end

  def self.jobs_fields : Array(String)
    SugarORM.sql("SELECT payload->>'fields' AS fields FROM caramel_jobs ORDER BY id",
      as: {fields: String}).map(&.[:fields])
  end
end

describe "SweetTalk's calendar days in queries" do
  it "finds a closed range of days, both ends in, across a leap day" do
    SweetTalkSpec.rolled_back do
      loans = CalendarDaysSpec.loans("2028-02-27", "2028-02-28", "2028-02-29", "2028-03-01",
        "2028-03-02")
      found = Library::Lending::Loan.borrowed_in(CalendarDaysSpec.day("2028-02-28"),
        CalendarDaysSpec.day("2028-03-01"))
      CalendarDaysSpec.ids(found).should eq(CalendarDaysSpec.ids(loans[1..3]))
      Library::Lending::Loan.borrowed_in(CalendarDaysSpec.day("2028-03-01"),
        CalendarDaysSpec.day("2028-02-28")).should be_empty
    end
  end

  it "finds the days before, from and on a day, and a day not yet given" do
    SweetTalkSpec.rolled_back do
      loans = CalendarDaysSpec.loans("2026-02-28", "2026-03-01", "2026-03-01", "2026-03-02")
      march = CalendarDaysSpec.day("2026-03-01")
      CalendarDaysSpec.ids(Library::Lending::Loan.borrowed_before(march))
        .should eq(CalendarDaysSpec.ids(loans[0, 1]))
      CalendarDaysSpec.ids(Library::Lending::Loan.borrowed_from(march))
        .should eq(CalendarDaysSpec.ids(loans[1..]))
      CalendarDaysSpec.ids(Library::Lending::Loan.borrowed_on_day(march))
        .should eq(CalendarDaysSpec.ids(loans[1, 2]))
      loans[1].give_back(CalendarDaysSpec.day("2026-03-05"))
      CalendarDaysSpec.ids(Library::Lending::Loan.still_out)
        .should eq(CalendarDaysSpec.ids([loans[0], loans[2], loans[3]]))
      fifth = CalendarDaysSpec.day("2026-03-05")
      CalendarDaysSpec.ids(Library::Lending::Loan.returned_on_day(fifth))
        .should eq([loans[1].id])
      Library::Lending::Loan.returned_since(CalendarDaysSpec.day("2026-03-05")).should eq(1)
      Library::Lending::Loan.returned_since(CalendarDaysSpec.day("2026-03-06")).should eq(0)
    end
  end

  it "sorts by day, id breaking ties" do
    SweetTalkSpec.rolled_back do
      loans = CalendarDaysSpec.loans("2026-03-02", "2026-01-15", "2026-03-02", "2025-12-31")
      CalendarDaysSpec.ids(Library::Lending::Loan.newest_first)
        .should eq([loans[0].id, loans[2].id, loans[1].id, loans[3].id])
      CalendarDaysSpec.ids(Library::Lending::Loan.oldest_first)
        .should eq([loans[3].id, loans[1].id, loans[0].id, loans[2].id])
    end
  end

  it "combines a range, a missing day, an order and a limit" do
    SweetTalkSpec.rolled_back do
      loans = CalendarDaysSpec.loans("2026-03-04", "2026-03-02", "2026-03-03", "2026-02-01",
        "2026-03-05")
      loans[1].give_back(CalendarDaysSpec.day("2026-03-06"))
      found = Library::Lending::Loan.still_out_oldest(CalendarDaysSpec.day("2026-03-01"),
        CalendarDaysSpec.day("2026-03-31"))
      CalendarDaysSpec.ids(found).should eq([loans[2].id, loans[0].id])
      Library::Lending::Loan.borrowed_count(CalendarDaysSpec.day("2026-03-01"),
        CalendarDaysSpec.day("2026-03-31")).should eq(4)
    end
  end

  it "reads a day in a specification the same in Crystal and PostgreSQL" do
    SweetTalkSpec.rolled_back do
      loans = CalendarDaysSpec.loans("2026-02-28", "2026-03-01", "2026-05-31", "2026-06-01",
        "2026-01-01")
      loans[1].give_back(CalendarDaysSpec.day("2026-06-01"))
      loans[2].give_back(CalendarDaysSpec.day("2026-05-31"))
      everything = Library::Lending::Loan.all
      CalendarDaysSpec.agree(Library::Lending::InSpring, everything, loans, [1, 2])
      CalendarDaysSpec.agree(Library::Lending::OnNewYear, everything, loans, [4])
      CalendarDaysSpec.agree(Library::Lending::Unreturned, everything, loans, [0, 3, 4])
      CalendarDaysSpec.agree(Library::Lending::ReturnedLate, everything, loans, [1])
      CalendarDaysSpec.agree(Library::Lending::BeforeSpring, everything, loans, [0, 4])
    end
  end
end

describe "SweetTalk's calendar days in events" do
  it "carries days in an event as ISO text, and hands them to a handler as emitted" do
    SweetTalkSpec.rolled_back do |connection|
      Library::Lending.returns.clear
      Library::Lending.renewals.clear
      loan = CalendarDaysSpec.loan("2026-03-01")
      loan.renew(CalendarDaysSpec.day("2026-03-29"))
      loan.give_back(CalendarDaysSpec.day("2026-03-09"))
      CalendarDaysSpec.jobs_fields.first.should eq(%({"until_day":"2026-03-29"}))
      CalendarDaysSpec.jobs_fields.last.should eq(
        %({"borrowed_on":"2026-03-01","returned_on":"2026-03-09"}))
      Caramel::ColdBrew.drain_queue(connection).should eq(3)
      Library::Lending.returns.should eq(["2026-03-01|2026-03-09"])
      Library::Lending.renewals.should eq(["2026-03-29"])
    end
  end

  it "carries an optional day as nil, and refuses a queued event whose day is not one" do
    meta = %({"id":"e1","at":"2026-03-01T00:00:00.000000Z","by":null,"cause":null,"flow":"f1"})
    returned = Library::Lending::Loan::Returned
    fields = %({"borrowed_on":"2026-03-01","returned_on":null})
    queued = returned.__sweettalk_load(7_i64, fields, meta)
    queued.returned_on.should be_nil
    queued.borrowed_on.to_s.should eq("2026-03-01")
    expect_raises(SweetTalk::Refusal, "Day must be a calendar day") do
      returned.__sweettalk_load(7_i64, %({"borrowed_on":"2026-02-30","returned_on":null}), meta)
    end
  end

  it "keeps a projection by day, whose key is a date column" do
    SweetTalkSpec.rolled_back do |connection|
      CalendarDaysSpec.column_type("lending_returns", "on_day").should eq("date")
      first = CalendarDaysSpec.loan("2026-03-01")
      second = CalendarDaysSpec.loan("2026-03-02")
      third = CalendarDaysSpec.loan("2026-03-02")
      first.give_back(CalendarDaysSpec.day("2026-03-09"))
      second.give_back(CalendarDaysSpec.day("2026-03-09"))
      third.give_back(CalendarDaysSpec.day("2026-03-10"))
      Caramel::ColdBrew.drain_queue(connection)
      rows = Library::Lending::Returns.all
      rows.map { |row| {row.on_day.to_s, row.books} }
        .should eq([{"2026-03-09", 2}, {"2026-03-10", 1}])
    end
  end
end

private struct Slip
  include JSON::Serializable

  getter lent_on : Library::Lending::Day
  getter back_on : Library::Lending::Day?
end

describe "SweetTalk's calendar days as JSON" do
  it "writes a day as its ISO text and reads it back" do
    day = CalendarDaysSpec.day("2026-03-01")
    day.to_json.should eq(%("2026-03-01"))
    [day].to_json.should eq(%(["2026-03-01"]))
    slip = Slip.from_json(%({"lent_on":"2026-03-01","back_on":null}))
    slip.lent_on.should eq(day)
    slip.back_on.should be_nil
    slip.to_json.should eq(%({"lent_on":"2026-03-01"}))
  end

  it "refuses what is not a day, as the calendar words it" do
    ["2026-02-30", "20260301", "1"].each do |text|
      expect_raises(JSON::ParseException, "Day must be a calendar day written YYYY-MM-DD") do
        Slip.from_json(%({"lent_on":"#{text}"}))
      end
    end
    expect_raises(JSON::ParseException) { Slip.from_json(%({"lent_on":20260301})) }
  end
end
