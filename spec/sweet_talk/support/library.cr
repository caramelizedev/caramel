# A library that lends books, for SweetTalk's calendar day: a required and an optional day
# in an aggregate, in an entity, as a part of a value with parts and as a projection's key;
# queries over a range of days, sorted by day, counted and read by a specification; and
# events that carry days.
require "../../../src/caramel/sweet_talk"

module Library
  include SweetTalk

  context Lending, means: "a library that lends books to readers" do
    value Day, Date, means: "a calendar day"

    value Term, means: "the days a book is out, from the day it left to the day it is due" do
      part left_on : Day
      part due_on : Day

      never("a book is due before it left") { due_on < left_on }
    end

    aggregate Loan, means: "one book lent to one reader" do
      has reader : String
      has borrowed_on : Day
      has returned_on : Day?
      has term : Term?
      has fines : Array(Fine)

      entity Fine, means: "a fine charged on a day, and the day it was waived" do
        has charged_on : Day
        has waived_on : Day?
      end

      event Returned, carries: [borrowed_on, returned_on], means: "a book came back"
      event Renewed, until_day : Day, means: "a loan was renewed until a day"

      finds borrowed_in(from : Day, to : Day), where: {borrowed_on: from..to}
      finds borrowed_before(day : Day), where: {borrowed_on: ...day}
      finds borrowed_from(day : Day), where: {borrowed_on: day..}
      finds borrowed_on_day(day : Day), where: {borrowed_on: day}
      finds still_out, where: {returned_on: nil}
      finds returned_on_day(day : Day), where: {returned_on: day}
      finds newest_first, order: {borrowed_on: :desc}
      finds oldest_first, order: {borrowed_on: :asc}
      finds still_out_oldest(from : Day, to : Day),
        where: {borrowed_on: from..to, returned_on: nil}, order: {borrowed_on: :asc}, first: 2
      counts borrowed_count(from : Day, to : Day), where: {borrowed_on: from..to}
      counts returned_since(day : Day), where: {returned_on: day..}

      to give_back(on : Day) do
        refuse "A book cannot come back before it left." if on < borrowed_on
        @returned_on = on
        emit Returned
      end

      to renew(until_day : Day) do
        refuse "A loan is renewed for a later day." if until_day <= borrowed_on
        emit Renewed, until_day: until_day
      end

      to set_term(term : Term?) do
        @term = term
      end

      to charge(on : Day, waived_on : Day?) do
        @fines << Fine.new(charged_on: on, waived_on: waived_on)
      end
    end

    projection Returns, means: "how many books came back on each day" do
      key on_day : Day
      has books : Int32 = 0

      whenever Loan::Returned do |returned|
        row = Returns[returned.returned_on.not_nil!]
        row.books = row.books + 1
      end
    end

    @@returns = [] of String
    @@renewals = [] of String

    # What each Returned and Renewed handler saw, as text, in the order they ran.
    def self.returns : Array(String)
      @@returns
    end

    def self.renewals : Array(String)
      @@renewals
    end

    whenever Loan::Returned do |returned|
      returns << "#{returned.borrowed_on}|#{returned.returned_on}"
    end

    whenever Loan::Renewed do |renewed|
      renewals << renewed.until_day.to_s
    end

    specification InSpring, on: Loan,
      where: {borrowed_on: Day.new(2026, 3, 1)..Day.new(2026, 5, 31)},
      means: "a loan made between 1 March and 31 May 2026"
    specification OnNewYear, on: Loan, where: {borrowed_on: Day.new(2026, 1, 1)},
      means: "a loan made on New Year's Day 2026"
    specification Unreturned, on: Loan, where: {returned_on: nil},
      means: "a loan whose book is still out"
    specification ReturnedLate, on: Loan, where: {returned_on: Day.new(2026, 6, 1)..},
      means: "a loan returned in June 2026 or later"
    specification BeforeSpring, on: Loan, where: {borrowed_on: ...Day.new(2026, 3, 1)},
      means: "a loan made before March 2026"
  end
end
