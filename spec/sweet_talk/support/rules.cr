# A small shelf for SweetTalk's rules: one aggregate per command, per handler and per
# service, unit-safe multiplication, a branching lifecycle, a factory whose event's
# policy runs as the actor who made the aggregate, values whose bounds and lengths
# PostgreSQL checks too, except one that opts out, a process whose steps may overlap and
# whose deadline a step arms for its own span, a policy whose first delivery fails, an
# entity a second aggregate stores again as its own, a two-word state, and a jar that
# specifications sort.
require "../../../src/caramel/sweet_talk"

module Rules
  include SweetTalk

  TALLEST = 3

  context Shelf, means: "a shelf for trying the rules" do
    value Count, Int32, at_least: 0, means: "how many things are in a box"
    value Price, Int64, at_least: 0, times: Count, means: "what one thing costs"

    aggregate Box, means: "a box on the shelf" do
      has label : String
      has count : Count
      moves draft >> live >> sold, draft >> scrapped, live >> scrapped

      event Shared, means: "a box asked every box to be tagged"
      event Tallied, by : Int32, pause : Int32, means: "a box was counted again"
      event Noted, means: "a box asked to be noted down"

      to tally(by : Int32, pause : Int32 = 0) do
        emit Tallied, by: by, pause: pause
      end

      to note do
        emit Noted
      end

      to fill(count : Count) do
        @count += count
      end

      to fill_with(other : Box) do
        @count += Count.new(1)
        other.fill Count.new(1)
      end

      to tag(label : String) do
        @label = label
      end

      to share do
        emit Shared
      end

      to go_live do
        live!
      end

      to sell do
        sold!
      end

      to scrap do
        scrapped!
      end
    end

    aggregate Crate, means: "a crate on the shelf, signed by whoever made it" do
      has label : String
      has maker : String = "nobody"

      event Made, label : String, means: "someone made a crate"

      factory make(label : String) do
        emit Made, label: label
      end

      to sign(maker : String) do
        @maker = maker
      end
    end

    value Stack, Int32, at_most: TALLEST, database_check: false,
      means: "how many bins stand on one another"
    value Code, String, length: 2..4, means: "the code painted on a bin"
    value Tag, String, length: 2.., means: "a word written on a box"
    value Note, String, length: ...9, means: "a short note on a box"

    value Size, means: "the width and depth of a bin, in boxes" do
      part width : Count
      part depth : Count
    end

    aggregate Bin, means: "a bin whose values PostgreSQL checks too" do
      has stack : Stack
      has size : Size
      has code : Code
    end

    aggregate Rack, means: "a rack whose slots each hold a box" do
      has slots : Array(Slot)

      entity Slot, means: "one place on a rack, holding one box" do
        has box : Box
      end
    end

    aggregate Tab, means: "money owed for one box" do
      has label : String
      moves awaiting_payment >> paid

      finds awaiting, where: {state: :awaiting_payment}

      to relabel(label : String) do
        @label = label
      end

      to pay do
        paid!
      end
    end

    aggregate Jar, means: "a jar of loose tea, which specifications sort" do
      has label : String
      has count : Count
      has size : Size
      has sealed : Bool = false
      has note : String? = nil
      moves on_shelf >> sold_out, on_shelf >> scrapped
      never "A jar on sale needs a label." { on_sale? && label.blank? }

      finds on_sale_labelled(label : String), where: {label: label}, satisfying: OnSale
      finds sold_out_jars, where: {state: :sold_out}
      finds fullest(count : Int32), order: {count: :desc}, first: count
      finds by_label, order: {label: :asc}
      finds on_sale_fullest, satisfying: OnSale, order: {count: :desc, label: :asc}
      finds wide_newest(count : Int32),
        where: {size: Size.new(width: Count.new(2), depth: Count.new(2))},
        order: {id: :desc}, first: count
      counts on_sale_count, satisfying: OnSale
      counts gifts, where: {note: "gift"}
      counts live_jars

      # One transaction stamps every row it creates alike, so id breaks the tie.
      finds newest(count : Int32) do |jars|
        jars.order_by(:created_at, :desc).order_by(:id, :desc).limit(count)
      end

      finds labelled_like(prefix : String) do |jars|
        jars.where("label LIKE ?", "#{prefix}%").order_by(:label, :asc)
      end

      to sell_out do
        refuse "Only a jar on sale sells out." unless on_sale?
        sold_out!
      end

      to scrap do
        scrapped!
      end

      to relabel(label : String) do
        @label = label
      end

      to forget do
        refuse "Only a scrapped jar can be forgotten." unless scrapped?
        remove
      end
    end

    specification OnSale, on: Jar, where: {state: :on_shelf, sealed: true},
      means: "a sealed jar still on the shelf"
    specification Full, on: Jar, where: {count: Count.new(5)..}, means: "a jar of five or more"
    specification Gift, on: Jar, where: {note: "gift"}, means: "a jar set aside as a gift"
    specification Plain, on: Jar, where: !Gift, means: "a jar not set aside as a gift"
    specification Wide, on: Jar, where: {size: Size.new(width: Count.new(2), depth: Count.new(2))},
      means: "a jar in a two-by-two bin"
    specification Unnoted, on: Jar, where: {note: nil}, means: "a jar without a note"
    specification Gone, on: Jar, where: {state: [:sold_out, :scrapped]},
      means: "a jar no longer on the shelf"
    # Gift first: the removed jar 6 is full, so it reaches PostgreSQL's last OR operand,
    # which only the parentheses where_condition adds keep behind removed_at IS NULL.
    specification Stocked, on: Jar, where: Gift | Full, means: "a jar that is full or a gift"
    specification Featured, on: Jar, where: OnSale & Stocked,
      means: "a jar on sale that is full or a gift"

    process Tally, means: "how much a box was counted, until it goes quiet" do
      key box : Box
      has total : Int32 = 0

      whenever Box::Tallied, key: tallied.box_id do |tallied|
        @total += tallied.by
        arm quiet, after: tallied.by.hours
        sleep tallied.pause.milliseconds
      end

      deadline quiet, after: 1.day do
        @total = 0
      end
    end

    @@notes = [] of String

    # The event ids the Noted policy has seen, one per delivery.
    def self.notes : Array(String)
      @@notes
    end

    whenever Box::Shared do |shared|
      Box.all.each(&.tag("shared"))
    end

    whenever Crate::Made do |made|
      Crate.find(made.crate_id).sign made.actor || "nobody"
    end

    whenever Box::Noted do |noted|
      notes << noted.event_id
      raise "the first delivery of a note fails" if notes.count(noted.event_id) == 1
    end

    service fill_two(first : Box::Id, second : Box::Id), means: "fills two boxes in one call" do
      Box.find(first).fill Count.new(1)
      Box.find(second).fill Count.new(1)
    end
  end
end
