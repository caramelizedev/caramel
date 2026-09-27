require "../../../src/caramel"

# The RFC-0003 code blocks, verbatim between the scaffolding markers.
# scripts/check cold-brew-compilation type-checks this file; nothing runs.

# --- scaffolding ---
module Stripe
  class RateLimitError < Exception
  end
end

struct Invite < SugarORM::Schema
  schema "invites" do
    field id : Int64, primary: true
    field email : String
  end
end

struct CleanupJob < Caramel::ColdBrew::Job
  def perform
  end
end

# --- RFC-0003 §2.1 ---
# app/jobs/send_invitation.cr
struct SendInvitation < Caramel::ColdBrew::Job
  queue "mailers"
  retry_on Stripe::RateLimitError, attempts: 5, backoff: :exponential, base: 2.seconds
  param invite_id : Int64

  def perform
    # …
  end
end

SugarORM::Repo.transaction do
  invite = Invite.create!(email: "elena@acme.com")
  SendInvitation.enqueue(invite_id: invite.id)   # same transaction: no dual write
end

# --- RFC-0003 §2.2 ---
Caramel::ColdBrew.every(1.hour, "nightly-cleanup") { CleanupJob.enqueue }

# --- RFC-0003 §2.3 ---
struct Boards::Live < Caramel::Action
  contract do
    field board_id : Int64
  end

  def handle(contract : Contract)
    channel = Channel(String).new
    Caramel::ColdBrew.subscribe("board_#{contract.board_id}", channel)

    stream "text/event-stream" do |io|
      loop do
        io << "event: BoardUpdated\ndata: " << channel.receive << "\n\n"
        io.flush
      end
    end
  end
end

# --- scaffolding: routing type-checks Boards::Live#handle ---
Caramel::Router.draw do
  get "/boards/:board_id/live", Boards::Live
end
