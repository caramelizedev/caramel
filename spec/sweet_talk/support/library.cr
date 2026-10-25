# A library that lends books, for SweetTalk's calendar day: a required and an optional day
# in an aggregate, in an entity and as a part of a value with parts.
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

      to give_back(on : Day) do
        refuse "A book cannot come back before it left." if on < borrowed_on
        @returned_on = on
      end

      to set_term(term : Term?) do
        @term = term
      end

      to charge(on : Day, waived_on : Day?) do
        @fines << Fine.new(charged_on: on, waived_on: waived_on)
      end
    end
  end
end
