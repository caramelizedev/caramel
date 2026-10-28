# The Ledger domain, in SweetTalk (ADRs 0030 and 0031). Its words, such as
# context, value, aggregate, event and whenever, exist only inside this module.
module App::Ledger
  include SweetTalk
  tenant App::Account

  context Books, subdomain: :core, means: "what each heading was posted in each period" do
    value Cents, Int64, means: "an amount in minor units; a credit is negative"
    value Heading, String, length: 1..40, means: "what an amount is posted under, such as sales"
    value Period, String, matches: /\A\d{4}-(0[1-9]|1[0-2])\z/,
      means: "a calendar month written YYYY-MM"

    aggregate Journal, means: "the lines posted together to one period" do
      has period : Period
      has lines : Array(Line)
      moves open >> posted

      entity Line, means: "one amount under one heading" do
        has heading : Heading
        has amount : Cents
      end

      event Posted, period : Period, lines : Array(Line),
        means: "the journal's lines reached the books"

      factory open(period : Period) do
      end

      to add(heading : Heading, amount : Cents) do
        refuse "A posted journal takes no more lines." if posted?
        @lines << Line.new(heading, amount)
      end

      to post do
        refuse "The journal is already posted." if posted?
        refuse "An empty journal cannot be posted." if lines.empty?
        posted!
        emit Posted, period: period, lines: lines
      end
    end

    value Slot, means: "one heading in one period" do
      part heading : Heading
      part period : Period
    end

    projection Balance, means: "what one heading was posted in one period" do
      key slot : Slot
      has total : Cents = Cents.new(0_i64)
      has postings : Int32 = 0

      whenever Journal::Posted, each: :lines do |posted, line|
        row = Balance[Slot.new(heading: line.heading, period: posted.period)]
        row.total += line.amount
        row.postings += 1
      end

      finds in_period(period : Period) do |rows|
        rows.where(slot_period: period.raw)
      end

      finds for_heading(heading : Heading) do |rows|
        rows.where(slot_heading: heading.raw).order_by(:slot_period, :asc)
      end
    end

    service period_total(period : Period), returns: Cents,
      means: "everything posted to one period, across its headings" do
      Balance.in_period(period).sum(&.total)
    end
  end
end
