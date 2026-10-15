Learn / The Box Office path

# Sell every seat once.

Build a box office in SweetTalk: seats held for ten minutes, sold once, and offered to a waitlist when a hold runs out, with specs that prove the refusal, the timer and the waitlist.

| Contract | Value |
| --- | --- |
| Needs | A Caramel installation set up as in [Your first application](https://caramelize.dev/docs/0.15.0/getting-started/index.md) |
| You will have | A `boxoffice` application whose SweetTalk domain holds, sells and releases seats and keeps a waitlist, with two pages and passing specs |
| Status | Run end to end by `scripts/check page-boxoffice`; SweetTalk itself is experimental |
| Proved by | `frappe check` · `frappe corretto` · `frappe lint` |

Two guests see the last two seats of a show at the same moment. Code that reads the free seats, checks them and writes a hold lets both through, and the show is oversold. A SweetTalk command locks its aggregate’s row and reads it again before it runs, so the second guest is refused; Caramel’s own specs prove that lock. This path builds a box office on that rule.

[Read how a command runs →](https://caramelize.dev/docs/0.15.0/sweettalk/index.md)

## 01 · Create the application and its domain {#c-boxoffice-create}

Create the application, then start its SweetTalk domain with one context, Seating.

**Terminal · after machine setup**

```bash
frappe new boxoffice
cd boxoffice
```

**Expect:** Prints `Created boxoffice.`, then `boxoffice is configured at https://boxoffice.caramel`.

**Terminal · inside boxoffice**

```bash
frappe make domain BoxOffice Seating --means="selling the seats of each show"
```

**Expect:** Prints `Generated` for each of the four files it writes, `app/domain/box_office.cr` first, then a `Next:` line that names `frappe db diff --name create_box_office`.

## 02 · Give each show its seats {#c-boxoffice-show}

Replace `app/domain/box_office.cr` with the five parts in steps 02 to 05, pasted in page order with a blank line between them. Each caption says where its part goes. A snippet drops the indentation of its place; `frappe format` puts it back. A show owns its capacity, the holds still waiting for payment and the tickets already paid for, so one aggregate sees every seat.

**app/domain/box_office.cr · part 1 of 5 · opens the module, context Seating and aggregate Show**

```crystal
# The BoxOffice domain, in SweetTalk (ADRs 0030 and 0031). Its words, such as
# context, value, aggregate, event and whenever, exist only inside this module.
module App::BoxOffice
  include SweetTalk

  context Seating, subdomain: :core, means: "selling the seats of each show" do
    HOLD_FOR = 10.minutes

    value Capacity, Int32, within: 1..5000, means: "the seats a show can sell"
    value Seats, Int32, within: 1..8, means: "the seats one guest takes at one checkout"
    value Email, String, matches: /\A[^@\s]+@[^@\s]+\z/, length: 3..254,
      means: "where we send a guest's tickets"

    aggregate Show, means: "one performance and the seats it sells" do
      has title : String
      has starts_at : Time
      has capacity : Capacity
      has issued : Int32 = 0
      has holds : Array(Hold)
      has tickets : Array(Ticket)
      moves on_sale >> closed
      never "A show cannot sell more seats than it has." { sold + held > capacity.to_i }

      entity Hold, means: "seats kept for one guest while they pay" do
        has number : Int32
        has guest : Email
        has seats : Seats
        has expires_at : Time
      end

      entity Ticket, means: "seats one guest paid for" do
        has number : Int32
        has guest : Email
        has seats : Seats
      end

      the held : Int32 = holds.sum(&.seats.to_i)
      the sold : Int32 = tickets.sum(&.seats.to_i)
      the left : Int32 = capacity.to_i - sold - held
```

Values name the capacity, the seats and the email, with their bounds. `the` derives what is held, sold and left from what the show stores. `moves` gives the show two states, on sale and closed, and `never` is the rule every command keeps; a command’s own `refuse` tells the guest why first. The guide states each word’s rules.

[Read the SweetTalk guide →](https://caramelize.dev/docs/0.15.0/sweettalk/index.md)

## 03 · Hold, sell and release seats {#c-boxoffice-hold}

**app/domain/box_office.cr · part 2 of 5 · inside aggregate Show, after the left; its last end closes the aggregate**

```crystal
  event Scheduled, means: "a show went on sale"
  event Held, number : Int32, guest : Email, seats : Seats, expires_at : Time,
    means: "seats were kept for a guest until a time"
  event Sold, number : Int32, guest : Email, seats : Seats,
    means: "a guest paid for the seats held for them"
  event Released, number : Int32, seats : Seats, reason : String,
    means: "held seats went back on sale, and why"

  factory schedule(title : String, starts_at : Time, capacity : Capacity) do
    emit Scheduled
  end

  to hold(guest : Email, seats : Seats) do
    refuse "Sales for #{title} have closed." if closed?
    refuse "#{title} is sold out." if left.zero?
    refuse "Only #{left} of #{capacity.to_i} seats left for #{title}." if seats.to_i > left
    @issued += 1
    expires_at = Time.utc + HOLD_FOR
    @holds << Hold.new(@issued, guest, seats, expires_at)
    emit Held, number: @issued, guest: guest, seats: seats, expires_at: expires_at
  end

  to sell(number : Int32) do
    hold = holds.find { |kept| kept.number == number }
    refuse "Hold #{number} is no longer held." unless hold
    @holds.reject! { |kept| kept.number == number }
    @tickets << Ticket.new(number, hold.guest, hold.seats)
    emit Sold, number: number, guest: hold.guest, seats: hold.seats
  end

  to release(number : Int32, reason : String) do
    if hold = holds.find { |kept| kept.number == number }
      @holds.reject! { |kept| kept.number == number }
      emit Released, number: number, seats: hold.seats, reason: reason
    end
  end

  to close do
    closed!
  end
end
```

Each command changes the one show it runs on. `hold` refuses with a reason the guest can act on, then keeps the seats for `HOLD_FOR`, the ten minutes at the top of the context. `sell` turns a hold into a ticket; the button that calls it stands in for a payment, which belongs in a border with the card gateway. `release` gives the seats back and does nothing when the hold has already ended, so a timer that fires late cannot undo a sale. `close` ends sales; no page calls it here, and the specs in step 10 do. Each event records the facts the next steps need.

## 04 · Release unpaid seats after ten minutes {#c-boxoffice-timer}

**app/domain/box_office.cr · part 3 of 5 · inside context Seating, after aggregate Show**

```crystal
value Claim, means: "one hold on one show" do
  part show : Int64
  part number : Int32
end

process Checkout, means: "the time one guest has to pay for the seats held for them" do
  key claim : Claim

  whenever Show::Held,
    key: Claim.new(show: held.show_id.raw, number: held.number) do |held|
    arm lapse, after: held.expires_at - Time.utc
  end

  whenever Show::Sold,
    key: Claim.new(show: sold.show_id.raw, number: sold.number) do |sold|
    disarm lapse
  end

  whenever Show::Released,
    key: Claim.new(show: released.show_id.raw, number: released.number) do |released|
    disarm lapse
  end

  deadline lapse, after: HOLD_FOR do
    Show.find(Show::Id.new(claim.show)).release(claim.number, "not paid in time")
  end
end
```

The process keeps one row per hold, picked by its claim; its steps are the jobs the guide’s Run processes section describes. A hold arms the deadline for its expiry time, and a sale or a release disarms it. When the ten minutes pass first, the deadline releases the seats.

## 05 · Offer released seats to the waitlist {#c-boxoffice-waitlist}

Seating answers an offer from the waitlist inside `border Waitlist`, reading only the event’s facts. Naming `Waitlist::Line` there would draw a dependency edge back to Waitlist, a cycle the guide’s context rules refuse. When someone else took the seats first, the hold is refused and the compensation leaves the guest in the line.

**app/domain/box_office.cr · part 4 of 5 · inside context Seating, after process Checkout; its last end closes the context**

```crystal
  border Waitlist do
    whenever Waitlist::Line::Offered do |offered|
      Show.find(offered.show).hold(offered.email, offered.seats)
    end

    compensate Waitlist::Line::Offered do |offered, refusal|
      # The seats went to someone else first: the guest stays in the line.
    end
  end
end
```

The waitlist is a second context that follows Seating. Its policies react to Seating’s events: a scheduled show gets an empty line, a new hold seats its guest if they were waiting, and released seats are offered to the first guest they fit. An offer sends the guest nothing yet: it holds the seats for them at once, and the hold page of step 07 shows them.

**app/domain/box_office.cr · part 5 of 5 · after context Seating; its last end closes the module**

```crystal
  context Waitlist, follows: Seating, subdomain: :supporting,
    means: "guests waiting for the seats a show gives back" do
    aggregate Line, means: "the guests waiting for one show, first come, first served" do
      has show : Seating::Show
      has guests : Array(Guest)

      entity Guest, means: "one guest in the line, and the seats they want" do
        has email : Seating::Email
        has seats : Seating::Seats
      end

      event Offered, show : Seating::Show::Id, email : Seating::Email, seats : Seating::Seats,
        means: "seats came free for the first guest in the line they fit"

      finds for_show(show : Seating::Show::Id), where: {show: show}

      to join(email : Seating::Email, seats : Seating::Seats) do
        waiting = guests.any? { |guest| guest.email.raw == email.raw }
        refuse "#{email.raw} is already waiting." if waiting
        @guests << Guest.new(email, seats)
      end

      to offer(free : Int32) do
        if first = guests.find { |guest| guest.seats.to_i <= free }
          emit Offered, show: show, email: first.email, seats: first.seats
        end
      end

      to seat(email : Seating::Email) do
        @guests.reject! { |guest| guest.email.raw == email.raw }
      end
    end

    whenever Seating::Show::Scheduled do |scheduled|
      Line.create(show: scheduled.show_id)
    end

    whenever Seating::Show::Held do |held|
      Line.for_show(held.show_id).first?.try(&.seat(held.guest))
    end

    whenever Seating::Show::Released do |released|
      free = Seating::Show.find(released.show_id).left
      Line.for_show(released.show_id).first?.try(&.offer(free))
    end
  end
end
```

The domain is complete. Compile it before it touches the database.

**Terminal · inside boxoffice**

```bash
frappe format
frappe check
```

**Expect:** `frappe format` restores each part’s indentation. `frappe check` prints `✓ Type check passed`.

## 06 · Derive the tables {#c-boxoffice-tables}

Let SugarORM derive the tables, review the migration, then apply it.

**Terminal · inside boxoffice**

```bash
frappe db diff --name create_box_office
```

**Expect:** Prints `Wrote` and the path of one migration ending in `_create_box_office.cr`. It creates `seating_shows`, `seating_show_holds`, `seating_show_tickets`, `seating_checkouts`, `waitlist_lines` and `waitlist_line_guests`, with `CHECK` constraints for the capacity, the seats, the email’s length and the show’s states.

**Terminal · inside boxoffice**

```bash
frappe migrate
```

**Expect:** Prints `Applied 1 migrations.`, then `The database matches the declared schema.`

## 07 · Let the show choose the buttons {#c-boxoffice-views}

The pages read the show. A closed show offers nothing, a show with seats left offers Hold seats, and a sold-out show offers Join the waitlist. The hold page offers payment while the hold lasts; afterwards it shows the tickets, or says that the seats went back on sale.

**app/views/shows/show.cr**

```crystal
module App::Views::Shows
  class Show < App::ApplicationView
    def initialize(@show : BoxOffice::Seating::Show, @csrf_token : String)
    end

    private def blueprint
      section class: "show" do
        h1 { @show.title }
        p { @show.starts_at.to_s("%A %d %B %Y, %H:%M UTC") }
        p { "#{@show.left} of #{@show.capacity.to_i} seats left" }
        if @show.closed?
          p { "Sales for this show have closed." }
        elsif @show.left > 0
          seats_form("holds", "Hold seats")
        else
          seats_form("waitlist", "Join the waitlist")
        end
      end
    end

    private def seats_form(path : String, submit : String) : Nil
      form action: "/shows/#{@show.id.raw}/#{path}", method: "post" do
        input type: "hidden", name: "_csrf", value: @csrf_token
        label(for: "guest") { "Email" }
        input id: "guest", type: "email", name: "guest", required: true
        label(for: "seats") { "Seats" }
        input id: "seats", type: "number", name: "seats", value: "1", required: true
        button(type: "submit") { submit }
      end
    end
  end
end
```

**app/views/holds/show.cr**

```crystal
module App::Views::Holds
  class Show < App::ApplicationView
    def initialize(@show : BoxOffice::Seating::Show, @number : Int32, @csrf_token : String)
    end

    private def blueprint
      section class: "hold" do
        h1 { @show.title }
        if hold = @show.holds.find { |kept| kept.number == @number }
          due = hold.expires_at.to_s("%H:%M")
          p { "#{hold.seats.to_i} seats held for #{hold.guest.raw} until #{due} UTC." }
          form action: "/shows/#{@show.id.raw}/holds/#{@number}/sale", method: "post" do
            input type: "hidden", name: "_csrf", value: @csrf_token
            button(type: "submit") { "Pay for the seats" }
          end
        elsif ticket = @show.tickets.find { |sold| sold.number == @number }
          p { "Paid: #{ticket.seats.to_i} seats. The tickets go to #{ticket.guest.raw}." }
        else
          p { "This hold has ended, and its seats went back on sale." }
          a(href: "/shows/#{@show.id.raw}") { "Back to #{@show.title}" }
        end
      end
    end
  end
end
```

**Terminal · inside boxoffice**

```bash
frappe check
```

**Expect:** Prints `✓ Type check passed`: the views compile before anything routes to them.

## 08 · Answer guests from actions {#c-boxoffice-actions}

Add the routes to `config/routes.cr`, inside `Caramel::Router.draw` and above the `# Frappé resource routes` comment, then one action per route. A contract field may be a SweetTalk value or a show’s id, so a bad value is refused before `handle` runs and a refused hold answers 422; the guide’s Call the domain from actions section lists what each client gets.

**config/routes.cr · inside Caramel::Router.draw**

```crystal
get "/shows/:show", App::Shows::Show
post "/shows/:show/holds", App::Holds::Create
get "/shows/:show/holds/:hold", App::Holds::Show
post "/shows/:show/holds/:hold/sale", App::Holds::Sell
post "/shows/:show/waitlist", App::Waitlists::Join
```

**app/actions/shows/show.cr**

```crystal
module App::Shows
  struct Show < App::ApplicationAction
    contract do
      field show : BoxOffice::Seating::Show::Id
    end

    def handle(contract : Contract)
      show = BoxOffice::Seating::Show.find(contract.show)
      page show.title, Views::Shows::Show.new(show, csrf_token)
    end
  end
end
```

**app/actions/holds/create.cr**

```crystal
module App::Holds
  struct Create < App::ApplicationAction
    contract do
      field show : BoxOffice::Seating::Show::Id
      field guest : BoxOffice::Seating::Email
      field seats : BoxOffice::Seating::Seats
    end

    def handle(contract : Contract)
      show = BoxOffice::Seating::Show.find(contract.show)
      show.hold(contract.guest, contract.seats)
      redirect_to("/shows/#{show.id.raw}/holds/#{show.issued}")
    end
  end
end
```

**app/actions/holds/show.cr**

```crystal
module App::Holds
  struct Show < App::ApplicationAction
    contract do
      field show : BoxOffice::Seating::Show::Id
      field hold : Int32, min: 1
    end

    def handle(contract : Contract)
      show = BoxOffice::Seating::Show.find(contract.show)
      page "Your seats", Views::Holds::Show.new(show, contract.hold, csrf_token)
    end
  end
end
```

**app/actions/holds/sell.cr**

```crystal
module App::Holds
  struct Sell < App::ApplicationAction
    contract do
      field show : BoxOffice::Seating::Show::Id
      field hold : Int32, min: 1
    end

    def handle(contract : Contract)
      BoxOffice::Seating::Show.find(contract.show).sell(contract.hold)
      redirect_to("/shows/#{contract.show.raw}/holds/#{contract.hold}")
    end
  end
end
```

**app/actions/waitlists/join.cr**

```crystal
module App::Waitlists
  struct Join < App::ApplicationAction
    contract do
      field show : BoxOffice::Seating::Show::Id
      field guest : BoxOffice::Seating::Email
      field seats : BoxOffice::Seating::Seats
    end

    def handle(contract : Contract)
      line = BoxOffice::Waitlist::Line.for_show(contract.show).first?
      return not_found unless line
      line.join(contract.guest, contract.seats)
      redirect_to("/shows/#{contract.show.raw}")
    end
  end
end
```

**Terminal · inside boxoffice**

```bash
frappe routes shows
```

**Expect:** Lists the five routes with their contracts, such as `POST /shows/:show/holds App::Holds::Create show:Show::Id(Int64) guest:Seating::Email(String) seats:Seating::Seats(Int32)`.

## 09 · Open the box office {#c-boxoffice-open}

Seed one show, then serve the application.

**db/seeds.cr**

```crystal
module App
  # Schedules one show the first time it runs; a second run finds it and does nothing.
  def self.seed(db : DB::Database) : Nil
    return unless BoxOffice::Seating::Show.all.empty?

    BoxOffice::Seating::Show.schedule("The Tempest", Time.utc + 30.days,
      BoxOffice::Seating::Capacity.new(120))
    puts "Scheduled The Tempest with 120 seats."
  end
end
```

**Terminal · inside boxoffice**

```bash
frappe seed
```

**Expect:** Prints `Scheduled The Tempest with 120 seats.` A second run does not print it, and schedules nothing.

**Terminal · inside boxoffice**

```bash
frappe dev
```

**Expect:** Builds the application and serves it at `https://boxoffice.caramel`; Ctrl-C stops it. `/shows/1` shows The Tempest, 120 of 120 seats left and a Hold seats button, and `/shows/2` answers 404.

## 10 · Specify the rules {#c-boxoffice-specs}

Add the builders both specs share, replace the generated domain spec and add a request spec. A spec starts no worker: `Caramel::ColdBrew.drain_queue!(db)` runs the jobs a command enqueued, and `include_scheduled: true` runs the deadline whose time has not come. The Cold Brew reference states both.

[Read how a spec drains the queue →](https://caramelize.dev/docs/0.15.0/cold-brew/index.md)

**spec/support/box_office.cr**

```crystal
# Builders and readers that the box office's specs share.
module BoxOfficeSpec
  extend self

  def show(capacity : Int32) : App::BoxOffice::Seating::Show
    App::BoxOffice::Seating::Show.schedule("The Tempest", Time.utc(2026, 11, 20, 19, 30),
      App::BoxOffice::Seating::Capacity.new(capacity))
  end

  def email(text : String) : App::BoxOffice::Seating::Email
    App::BoxOffice::Seating::Email.new(text)
  end

  def seats(count : Int32) : App::BoxOffice::Seating::Seats
    App::BoxOffice::Seating::Seats.new(count)
  end

  def reload(show : App::BoxOffice::Seating::Show) : App::BoxOffice::Seating::Show
    App::BoxOffice::Seating::Show.find(show.id)
  end

  def line(show : App::BoxOffice::Seating::Show) : App::BoxOffice::Waitlist::Line
    App::BoxOffice::Waitlist::Line.for_show(show.id).first
  end
end
```

**spec/domain/box_office_spec.cr**

```crystal
require "../spec_helper"
require "../support/box_office"

describe App::BoxOffice do
  it "refuses a hold for more seats than are left" do
    Corretto.session do |_client, _db|
      show = BoxOfficeSpec.show(3)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      expect_raises(SweetTalk::Refusal, "Only 1 of 3 seats left for The Tempest.") do
        show.hold(BoxOfficeSpec.email("bo@example.com"), BoxOfficeSpec.seats(2))
      end
      BoxOfficeSpec.reload(show).left.should eq(1)
    end
  end

  it "refuses a hold once sales have closed" do
    Corretto.session do |_client, _db|
      show = BoxOfficeSpec.show(2)
      show.close
      expect_raises(SweetTalk::Refusal, "Sales for The Tempest have closed.") do
        show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(1))
      end
    end
  end

  it "releases unpaid seats when the ten minutes run out" do
    Corretto.session do |_client, db|
      show = BoxOfficeSpec.show(2)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      Caramel::ColdBrew.drain_queue!(db)
      due = db.query_one("SELECT run_at FROM caramel_jobs WHERE class_name = $1",
        "App::BoxOffice::Seating::Checkout::LapseDeadline", as: Time)
      (due - Time.utc - 10.minutes).abs.should be < 1.minute
      Caramel::ColdBrew.drain_queue!(db, include_scheduled: true)
      BoxOfficeSpec.reload(show).left.should eq(2)
    end
  end

  it "keeps paid seats when the timer runs out after payment" do
    Corretto.session do |_client, db|
      show = BoxOfficeSpec.show(2)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      Caramel::ColdBrew.drain_queue!(db)
      show.sell(1)
      Caramel::ColdBrew.drain_queue!(db, include_scheduled: true)
      sold = BoxOfficeSpec.reload(show)
      sold.tickets.map(&.guest.raw).should eq(["ada@example.com"])
      sold.left.should eq(0)
    end
  end

  it "offers released seats to the first guest in the line they fit" do
    Corretto.session do |_client, db|
      show = BoxOfficeSpec.show(2)
      Caramel::ColdBrew.drain_queue!(db)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(2))
      line = BoxOfficeSpec.line(show)
      line.join(BoxOfficeSpec.email("cy@example.com"), BoxOfficeSpec.seats(3))
      line.join(BoxOfficeSpec.email("di@example.com"), BoxOfficeSpec.seats(2))
      show.release(1, "changed plans")
      Caramel::ColdBrew.drain_queue!(db)
      BoxOfficeSpec.reload(show).holds.map(&.guest.raw).should eq(["di@example.com"])
      BoxOfficeSpec.line(show).guests.map(&.email.raw).should eq(["cy@example.com"])
    end
  end
end
```

**spec/requests/box_office_spec.cr**

```crystal
require "../spec_helper"
require "../support/box_office"

describe "The box office" do
  it "holds seats, sells them, and offers the waitlist once the show is sold out" do
    Corretto.session do |client, db|
      show = BoxOfficeSpec.show(2)
      Caramel::ColdBrew.drain_queue!(db)
      path = "/shows/#{show.id.raw}"
      client.get(path).should have_html {
        section(class: "show") { button(type: "submit") { "Hold seats" } }
      }
      held = client.post("#{path}/holds", params: {"guest" => "ada@example.com", "seats" => "2"})
      held.should redirect_to("#{path}/holds/1")
      client.follow_redirect.should have_html {
        section(class: "hold") { button(type: "submit") { "Pay for the seats" } }
      }
      client.get(path).should have_html {
        section(class: "show") { button(type: "submit") { "Join the waitlist" } }
      }
      joined = client.post("#{path}/waitlist",
        params: {"guest" => "bo@example.com", "seats" => "1"})
      joined.should redirect_to(path)
      BoxOfficeSpec.line(show).guests.map(&.email.raw).should eq(["bo@example.com"])
      client.post("#{path}/holds/1/sale").should redirect_to("#{path}/holds/1")
      client.follow_redirect.should have_html {
        section(class: "hold") { p { "Paid: 2 seats. The tickets go to ada@example.com." } }
      }
    end
  end

  it "answers 422 for a refusal or a bad value, and 404 for a show that is not a number" do
    Corretto.session do |client, _db|
      show = BoxOfficeSpec.show(1)
      show.hold(BoxOfficeSpec.email("ada@example.com"), BoxOfficeSpec.seats(1))
      path = "/shows/#{show.id.raw}/holds"
      json = {"Accept" => "application/json"}
      sold_out = client.post(path, headers: json,
        params: {"guest" => "bo@example.com", "seats" => "1"})
      sold_out.should have_status(422)
      sold_out.body.should eq(%({"errors":{"_base":["The Tempest is sold out."]}}))
      too_many = client.post(path, headers: json,
        params: {"guest" => "bo@example.com", "seats" => "9"})
      too_many.should have_status(422)
      too_many.body.should eq(%({"errors":{"seats":["Seats must be between 1 and 8"]}}))
      stray = client.post("/shows/abc/holds",
        params: {"guest" => "bo@example.com", "seats" => "1"})
      stray.should have_status(404)
    end
  end

  it "offers a closed show nothing" do
    Corretto.session do |client, _db|
      show = BoxOfficeSpec.show(2)
      show.close
      client.get("/shows/#{show.id.raw}").should have_html {
        section(class: "show") { p { "Sales for this show have closed." } }
      }
    end
  end
end
```

**Terminal · inside boxoffice**

```bash
frappe corretto
```

**Expect:** Runs every example, the box office’s eight included, and prints `examples, 0 failures` and `Corretto: 1 of 1 workers passed`.

Prove it

## Prove the box office works {#c-boxoffice-prove}

Run the three checks.

**Terminal · inside boxoffice**

```bash
frappe check
frappe corretto
frappe lint
```

**Passing:** `frappe check` prints `✓ Type check passed`, `frappe corretto` prints `Corretto: 1 of 1 workers passed`, and `frappe lint` exits 0.

[← SweetTalk](https://caramelize.dev/docs/0.15.0/sweettalk/index.md) · [Read every SweetTalk rule →](https://caramelize.dev/docs/0.15.0/sweettalk/index.md)

Caramel 0.15.0 · https://caramelize.dev/docs/0.15.0/box-office/
