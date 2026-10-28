require "../../../src/caramel/sweet_talk"
require "../../../src/caramel/tenancy"

module Shop
  include SweetTalk

  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
      index :slug, unique: true
    end
  end

  tenant Account

  context Ordering, means: "choosing teas and checking out" do
    aggregate Order, means: "what a member buys at one checkout" do
      has note : String

      to annotate(note : String) do
        @note = note
      end
    end
  end

  context Reporting, follows: Ordering, central: true, means: "figures every tenant shares" do
    aggregate Audit, means: "what we checked of one order" do
      has note : String

      to annotate(note : String) do
        @note = note
      end
    end

    unit audit(audit : Audit::Id, order : Ordering::Order::Id, note : String),
      changes: [Audit, Ordering::Order], locks: [audit, order],
      means: "annotates an audit and the order it checked together" do
      Audit.find(audit).annotate note
      Ordering::Order.find(order).annotate note
    end
  end

  struct Home < Caramel::Action
    ingress open: true

    contract do
    end

    def handle(contract : Contract)
      page "Home", "<p>Home</p>"
    end
  end

  Caramel::Router.draw do
    tenant Account, by: :slug do
      get "/", Home
    end
  end
end

SweetTalk.boot
