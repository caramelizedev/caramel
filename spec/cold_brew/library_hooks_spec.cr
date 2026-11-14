require "spec"
require "../../src/caramel"

# What libraries outside the framework use of Cold Brew's job registry; each
# declaration's comment says so. An example that fails, or no longer compiles, means
# such a library breaks.

module ColdBrewHooks
  struct Brew < Caramel::ColdBrew::Job
    def perform
    end
  end

  # Renamed from ColdBrewHooks::Drip.
  struct Pour < Caramel::ColdBrew::Job
    renamed_from "ColdBrewHooks::Drip"

    def perform
    end
  end
end

private alias Job = Caramel::ColdBrew::Job

describe "Cold Brew's hooks for libraries" do
  it "gives the current name of a job by a name it was stored under " \
     "through __cold_brew_canonical" do
    Job.__cold_brew_canonical(class_name: "ColdBrewHooks::Drip").should eq("ColdBrewHooks::Pour")
    Job.__cold_brew_canonical(class_name: "ColdBrewHooks::Pour").should eq("ColdBrewHooks::Pour")
    typeof(Job.__cold_brew_canonical(class_name: "ColdBrewHooks::Brew")).should eq(String?)
  end

  it "gives nil for a name no compiled job has" do
    Job.__cold_brew_canonical(class_name: "Gone::Job").should be_nil
  end

  it "lists every name a job may be stored under through __cold_brew_stored_names" do
    stored = Job.__cold_brew_stored_names(class_name: "ColdBrewHooks::Pour")
    stored.should eq(["ColdBrewHooks::Pour", "ColdBrewHooks::Drip"])
    typeof(stored).should eq(Array(String))
    unrenamed = Job.__cold_brew_stored_names(class_name: "ColdBrewHooks::Brew")
    unrenamed.should eq(["ColdBrewHooks::Brew"])
  end

  it "lists only the name itself when no compiled job has it" do
    Job.__cold_brew_stored_names(class_name: "Gone::Job").should eq(["Gone::Job"])
  end
end
