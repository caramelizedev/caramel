# A counter where money changes hands, for optional attributes of each stored kind (an
# aggregate, a value, a value with parts, an application's schema record), the same inside an
# entity, a projection and a process, and events that hand them to their handlers.
require "../../../src/caramel/sweet_talk"

module Ledger
  include SweetTalk

  # The application's own accounts, a plain SugarORM schema.
  struct Account < SugarORM::Schema
    schema "ledger_accounts" do
      field id : Int64, primary: true
      field email : String
    end
  end

  context Counter, means: "a counter where money changes hands" do
    value Currency, String, length: 3..3, means: "a currency the counter holds"
    value Kind, String, length: 3..20, means: "what a transfer does with the money"
    value Teller, String, length: 2..20, means: "who works at the desk"
    value Cents, Int64, at_least: 0, means: "an amount in minor units"
    value Reason, String, length: 3..40, means: "why a transfer was undone"

    value Money, means: "an amount in one currency" do
      part currency : Currency
      part cents : Cents
    end

    aggregate Owner, means: "who the counter pays" do
      has name : String
    end

    aggregate Transfer, means: "one movement of money across the counter" do
      has kind : Kind
      has amount : Money
      has opened_by : Teller
      has owner : Owner?
      has account : Account?
      has settled_by : Teller?
      has leg : Money?
      has reason : Reason?
      has note : String?
      has lines : Array(Line)
      moves open >> settled >> undone, open >> undone

      entity Line, means: "one part of a transfer, optionally for another owner" do
        has label : String
        has payee : Owner?
        has paid_by : Teller?
        has share : Money?
      end

      the line_count : Int32 = lines.size

      event Settled, kind : Kind, amount : Money, opened_by : Teller, owner : Owner::Id?,
        settled_by : Teller?, leg : Money?, lines : Array(Line), line_count : Int32,
        means: "a transfer was settled, with everything it said when it was"
      event Undone, note : String, owner : Owner::Id?, reason : Reason?,
        means: "a transfer was undone, and what the desk wrote about it"

      finds unassigned, where: {owner: nil}
      finds without_leg, where: {leg: nil}
      finds of_kind(kind : Kind), where: {kind: kind}
      finds opened_by_teller(teller : Teller), where: {opened_by: teller}
      finds by_reason_desc, order: {reason: :desc}
      finds by_reason_asc, order: {reason: :asc}
      counts settled_unattended, where: {settled_by: nil, state: :settled}

      to assign(owner : Owner) do
        self.owner = owner
      end

      to leave_unassigned do
        self.owner = nil
      end

      to settle(by : Teller) do
        refuse "A teller does not settle what they opened." if by == opened_by
        settled!
        @settled_by = by
        emit Settled, kind: kind, amount: amount, opened_by: opened_by, owner: owner,
          settled_by: settled_by, leg: leg, lines: lines, line_count: line_count
      end

      to use_account(account : Account?) do
        self.account = account
      end

      to give_back(leg : Money) do
        @leg = leg
      end

      to undo(reason : Reason?) do
        undone!
        @reason = reason
        emit Undone, note: "undone by the desk", owner: owner, reason: reason
      end

      to pay_line(label : String, payee : Owner?, paid_by : Teller?, share : Money?) do
        @lines << Line.new(label: label, payee: payee, paid_by: paid_by, share: share)
      end
    end

    aggregate Voucher, means: "a voucher the counter issues, with what it may say" do
      has remark : String?
      has owner : Owner?
      has issuer : Teller
      has kind : Kind
      event Issued, issuer : Teller, means: "a voucher was issued"

      factory issue(issuer : Teller, kind : Kind) do
        emit Issued, issuer: issuer
      end

      to remark_on(remark : String?) do
        @remark = remark
      end
    end

    projection Standing, means: "the last settlement of each owner" do
      key owner : Owner
      has last_settled_by : Teller?
      has last_leg : Money?
      has last_transfer : Transfer?

      finds without_leg, where: {last_leg: nil}

      whenever Transfer::Settled do |settled|
        if owner = settled.owner
          row = Standing[owner]
          row.last_settled_by = settled.settled_by
          row.last_leg = settled.leg
          row.last_transfer = settled.transfer_id
        end
      end
    end

    process Followup, means: "when a settled transfer was last followed up, and with what" do
      key transfer : Transfer
      has followed_by : Teller?
      has followed_with : Money?
      has followed_owner : Owner?

      whenever Transfer::Settled, key: settled.transfer_id do |settled|
        @followed_by = settled.settled_by
        @followed_with = settled.leg
        self.followed_owner = settled.owner
      end
    end

    @@settlements = [] of String
    @@undoings = [] of String

    # What each Settled and Undone handler saw, as text, in the order they ran.
    def self.settlements : Array(String)
      @@settlements
    end

    def self.undoings : Array(String)
      @@undoings
    end

    whenever Transfer::Settled do |settled|
      owner = settled.owner.try(&.raw)
      leg = settled.leg.try { |money| "#{money.currency}#{money.cents}" }
      facts = [settled.kind, settled.amount.cents, settled.opened_by, owner, settled.settled_by]
      facts += [leg, settled.lines.map(&.label).join("+"), settled.line_count]
      settlements << facts.join("|")
    end

    whenever Transfer::Undone do |undone|
      undoings << [undone.owner.try(&.raw), undone.reason, undone.note].join("|")
    end

    specification Unsettled, on: Transfer, where: {settled_by: nil},
      means: "a transfer nobody has settled"
    specification Unlegged, on: Transfer, where: {leg: nil},
      means: "a transfer with no returned leg"
    specification Receipts, on: Transfer, where: {kind: Kind.new("receipt")},
      means: "a transfer that takes money in"
  end
end
