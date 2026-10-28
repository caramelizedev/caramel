# A billing desk that keeps its event log (ADR 0048): invoices whose commands and a
# service's event are logged in `invoicing_events`, a projection rebuilt from the log, and
# a policy that runs after that projection's handler of the same event.
require "../../../src/caramel/sweet_talk"

module Billing
  include SweetTalk

  context Invoicing, event_log: true, means: "raising and settling invoices" do
    value Cents, Int64, at_least: 0, means: "an amount in minor units"

    aggregate Invoice, means: "what one customer owes for one order" do
      has customer : String
      has total : Cents
      moves open >> settled

      event Raised, carries: [customer, total], means: "an invoice was raised"
      event Settled, carries: [customer, total], means: "an invoice was paid in full"

      factory raise_for(customer : String, total : Cents) do
        emit Raised
      end

      to settle(paid : Cents) do
        refuse "An invoice is settled by its total." unless paid == total
        settled!
        emit Settled
      end
    end

    event Closed, period : String, means: "the books were closed for a period"

    service close(period : String), means: "closes the books for a period" do
      emit Closed, period: period
    end

    projection Owed, means: "what each customer was invoiced and has paid" do
      key customer : String
      has raised : Int64 = 0
      has settled : Int64 = 0

      whenever Invoice::Raised do |raised|
        Owed[raised.customer].raised += raised.total.raw
      end

      whenever Invoice::Settled do |settled|
        Owed[settled.customer].settled += settled.total.raw
      end
    end

    @@reminders = [] of String

    # What the policy that runs after Owed saw of the projection, in the order it ran.
    def self.reminders : Array(String)
      @@reminders
    end

    whenever Invoice::Raised, after: Owed do |raised|
      owed = Owed.all.find { |row| row.customer == raised.customer }
      reminders << "#{raised.customer} owes #{owed.try(&.raised)}"
    end
  end
end
