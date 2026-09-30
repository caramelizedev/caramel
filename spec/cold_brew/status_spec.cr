require "spec"
require "../../src/caramel"

private alias JobState = Caramel::ColdBrew::JobState

private def state(*, finished = false, failed = false, locked = false,
                  attempts = 0, due = true) : JobState
  Caramel::ColdBrew::JobStatus.state_for(
    finished: finished,
    failed: failed,
    locked: locked,
    attempts: attempts,
    due: due,
  )
end

describe Caramel::ColdBrew::JobStatus do
  it "derives a job's state from its row, terminal states first" do
    state(due: false).should eq(JobState::Scheduled)
    state.should eq(JobState::Queued)
    state(locked: true, attempts: 1).should eq(JobState::Running)
    state(attempts: 1, due: false).should eq(JobState::Retrying)
    state(attempts: 2).should eq(JobState::Retrying)
    state(finished: true, attempts: 1).should eq(JobState::Finished)
    state(failed: true, attempts: 3).should eq(JobState::Failed)
  end

  it "runs no query for an empty list of ids" do
    Caramel::ColdBrew.statuses([] of Int64).should be_empty
  end
end
