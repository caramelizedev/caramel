require "../spec_helper"

describe "Importing a book" do
  it "queues the import, and the book exists once the queue drains" do
    Corretto.session do |client, db|
      queued = client.post("/imports", headers: {"HX-Request" => "true"},
        params: {"title" => "Dune", "author" => "Frank Herbert"})
      queued.should have_status(202)
      queued.should render_partial("#imports")
      db.should_not have_row(App::Book, title: "Dune")
      Caramel::ColdBrew.drain_queue!(db, "imports").should eq(1)
      db.should have_row(App::Book, title: "Dune", author: "Frank Herbert")
      Caramel::ColdBrew.drain_queue!(db, "imports").should eq(0)
      id = db.query_one("SELECT max(id) FROM caramel_jobs", as: Int64)
      status = Caramel::ColdBrew.status(db, id)
      status.try(&.state).should eq(Caramel::ColdBrew::JobState::Finished)
    end
  end

  it "keeps no queue row when the transaction rolls back" do
    Corretto.session do |_client, db|
      SugarORM::Repo.transaction do
        App::ImportBook.enqueue(title: "Dropped", author: "Nobody")
        SugarORM::Repo.rollback
      end
      Caramel::ColdBrew.drain_queue!(db, "imports").should eq(0)
    end
  end
end
