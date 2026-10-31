# The Ledger domain, in SweetTalk (ADRs 0030 and 0031). Its words, such as
# context, value, aggregate, event and sums, exist only inside this module.
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

      sums posted_in(period : Period), of: Line.amount, where: {period: period, state: :posted}
      groups by_heading_in(period : Period), of: Line.amount, by: Line.heading,
        where: {period: period, state: :posted}
      groups by_heading, of: Line.amount, by: Line.heading, where: {state: :posted}
    end
  end
end
