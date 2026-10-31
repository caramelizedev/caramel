# A small shelf for SweetTalk's rules: one aggregate per command, per handler and per
# service, unit-safe multiplication, a branching lifecycle, a factory whose event's
# policy runs as the actor who made the aggregate, values whose bounds and lengths
# PostgreSQL checks too, except one that opts out, a process whose steps may overlap,
# whose deadline a step arms for its own span and which declares queries, a policy whose
# first delivery fails, a policy with its own retry rule, an entity a second aggregate
# stores again as its own, a two-word state, a jar that specifications sort, a service
# that emits the shelf's own event, which a second context follows, and units that change
# two boxes, or a box and a crate, in one transaction under ordered locks.
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
      event Twice, means: "a box asked to be filled twice"
      event Doubted, means: "a box asked to be sold, which a draft box refuses"
      event Tallied, by : Int32, pause : Int32, means: "a box was counted again"
      event Noted, means: "a box asked to be noted down"
      event Weighed, means: "a box was put on the scales"

      to tally(by : Int32, pause : Int32 = 0) do
        emit Tallied, by: by, pause: pause
      end

      to note do
        emit Noted
      end

      to weigh do
        emit Weighed
      end

      to fill(count : Count) do
        @count += count
      end

      to fill_with(other : Box) do
        @count += Count.new(1)
        other.fill Count.new(1)
      end

      to fill_both_with(other : Box) do
        Shelf.fill_both(self, other, 1)
      end

      to tag(label : String) do
        @label = label
      end

      to share do
        emit Shared
      end

      to fill_twice do
        emit Twice
      end

      to doubt do
        emit Doubted
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
    value Tip, Int32, at_least: 0, otherwise: "A tip cannot be negative.",
      means: "money left for the shelf"
    value Grade, String, one_of: %w[a b c], otherwise: "Grades run from a to c.",
      means: "how good a jar is"

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

      finds tallied_to(total : Int32), where: {total: total}
      counts tallies

      whenever Box::Tallied, key: tallied.box_id do |tallied|
        @total += tallied.by
        arm quiet, after: tallied.by.hours
        sleep tallied.pause.milliseconds
      end

      deadline quiet, after: 1.day, attempts: 2 do
        counted = Box.find(box)
        counted.fill Count.new(1)
        counted.fill Count.new(1)
        @total = 0
      end
    end

    @@notes = [] of String

    # The event ids the Noted policy has seen, one per delivery.
    def self.notes : Array(String)
      @@notes
    end

    @@weighings = [] of String

    # The event ids the Weighed policy has seen, one per delivery.
    def self.weighings : Array(String)
      @@weighings
    end

    whenever Box::Weighed, attempts: 3, backoff: :linear, base: 2.seconds do |weighed|
      weighings << weighed.event_id
      raise "the scales are busy" if weighings.count(weighed.event_id) < 3
    end

    whenever Box::Shared do |shared|
      Box.all.each(&.tag("shared"))
    end

    whenever Box::Twice do |twice|
      box = Box.find(twice.box_id)
      box.fill Count.new(1)
      box.fill Count.new(1)
    end

    whenever Box::Doubted do |doubted|
      Box.find(doubted.box_id).sell
    end

    compensate Box::Doubted do |doubted, refusal|
      box = Box.find(doubted.box_id)
      box.tag refusal.message.to_s
      box.fill Count.new(1)
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

    service fill_one_twice(box : Box::Id), means: "fills one box twice in one call" do
      found = Box.find(box)
      found.fill Count.new(1)
      found.fill Count.new(1)
    end

    service make_filled(label : String), returns: Box::Id,
      means: "creates a box and fills it in one call" do
      box = Box.create(label: label, count: Count.new(0))
      box.fill Count.new(1)
      box.id
    end

    service make_signed(label : String, maker : String), returns: Crate::Id,
      means: "makes a crate and signs it in one call" do
      crate = Crate.make(label)
      crate.sign maker
      crate.id
    end

    event Renamed, name : String, means: "the shelf was given a new name"

    service rename(name : String), means: "gives the shelf a new name" do
      emit Renamed, name: name
    end

    # Fills two boxes by one count, the two rows locked first in id order whichever way
    # the arguments come; a count of 13 raises after the second fill, and a box left with
    # more than nine things is refused by the set's rule.
    unit fill_both(first : Box, second : Box, by : Int32, pause : Int32 = 0),
      changes: [Box], locks: [first, second],
      means: "fills two boxes by one count in one transaction" do
      first.fill Count.new(by)
      sleep pause.milliseconds unless pause.zero?
      second.fill Count.new(by)
      raise "the shelf fell over" if by == 13
      never "A box holds at most nine things." { first.count.raw > 9 || second.count.raw > 9 }
    end

    unit tag_and_sign(box : Box::Id, crate : Crate::Id, word : String),
      changes: [Box, Crate], locks: [box, crate],
      means: "tags a box and signs a crate with one word in one transaction" do
      Box.find(box).tag word
      Crate.find(crate).sign word
    end

    unit tag_and_relabel(box : Box::Id, tab : Tab::Id, word : String), changes: [Box],
      locks: [box], means: "tags a box, then reaches a tab the unit does not change" do
      Box.find(box).tag word
      Tab.find(tab).relabel word
    end

    unit fill_unlocked(box : Box::Id, other : Box::Id), changes: [Box], locks: [box],
      means: "fills a box it locked, then one it did not" do
      Box.find(box).fill Count.new(1)
      Box.find(other).fill Count.new(1)
    end

    unit make_filled_pair(label : String), changes: [Box], returns: Box::Id,
      means: "creates a box and fills it, with nothing to lock" do
      box = Box.create(label: label, count: Count.new(0))
      box.fill Count.new(1)
      box.id
    end

    unit fill_both_twice(first : Box, second : Box), changes: [Box], locks: [first, second],
      means: "runs the fill_both unit inside a unit, which a unit refuses" do
      fill_both(first, second, 1)
    end

    service fill_both_served(first : Box::Id, second : Box::Id),
      means: "runs the fill_both unit as its one change" do
      fill_both(Box.find(first), Box.find(second), 1)
    end

    service fill_both_then_one(first : Box::Id, second : Box::Id),
      means: "runs the fill_both unit, then a command, which is one change too many" do
      fill_both(Box.find(first), Box.find(second), 1)
      Box.find(first).fill Count.new(1)
    end
  end

  context Signage, means: "the signs that say what the shelf is called" do
    aggregate Sign, means: "a sign naming the shelf" do
      has name : String
    end

    border Shelf do
      whenever Shelf::Renamed do |renamed|
        Sign.create(name: renamed.name)
      end
    end
  end
end
