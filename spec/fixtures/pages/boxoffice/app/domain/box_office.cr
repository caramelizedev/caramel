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

    border Waitlist do
      whenever Waitlist::Line::Offered do |offered|
        Show.find(offered.show).hold(offered.email, offered.seats)
      end

      compensate Waitlist::Line::Offered do |offered, refusal|
        # The seats went to someone else first: the guest stays in the line.
      end
    end
  end

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
