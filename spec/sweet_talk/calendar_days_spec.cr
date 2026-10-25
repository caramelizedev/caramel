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
      %(ALTER TABLE "lending_loans" ALTER COLUMN "borrowed_on" TYPE date USING "borrowed_on"::date))
  end
end
