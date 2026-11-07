# Corrections to books, for SweetTalk's reached events and pinned references (ADR 0056): a
# chain of events across three contexts that all keep a log, and a journal that copies the
# rules it was opened under when it is sealed.
require "../../../src/caramel/sweet_talk"

module Corrections
  include SweetTalk
  ids Int64

  context Setup, event_log: true, means: "the rules a book is kept under" do
    aggregate Rules, means: "what one book is charged and called" do
      has rate : Int64
      has label : String

      to reprice(rate : Int64) do
        @rate = rate
      end
    end
  end

  context Books, follows: Setup, event_log: true, means: "the journals a book keeps" do
    aggregate Journal, means: "one journal, sealed under the rules it was opened with" do
      has amount : Int64
      has rules : Setup::Rules, pinned_at: :finalized
      moves draft >> finalized

      event Opened, means: "a journal was opened"
      event Sealed, means: "a journal was sealed"

      factory open(amount : Int64, rules : Setup::Rules) do
        emit Opened
      end

      to seal do
        finalized!
        emit Sealed
      end
    end

    event Noted, batch : Int64, means: "a batch was noted in the books"

    service note(batch : Int64), means: "notes that a batch carried a journal" do
      emit Noted, batch: batch
    end

    publishes Journal, Journal::Id, note
  end

  context Carry, follows: Books, event_log: true, means: "carrying journals in batches" do
    aggregate Batch, means: "journals carried together" do
      has journal : Books::Journal

      event Started, means: "a batch began"

      factory start(journal : Books::Journal::Id) do
        emit Started
      end
    end

    border Books do
      whenever Books::Journal::Opened do |opened|
        Batch.start(opened.journal_id)
      end
    end

    whenever Batch::Started do |started|
      Books.note(started.batch_id.raw)
    end
  end
end
