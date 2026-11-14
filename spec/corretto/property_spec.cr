# Corretto's property cases (ADR 0010 decision 11) on plain class methods: arguments drawn
# from their types, a type's own generator, skipped cases, and a failure that names its
# case, its seed and its arguments.
require "spec"
require "../../src/caramel/corretto/property"

module PropertySpec
  # A point drawn by its own generator, on a board of ten by ten.
  struct Point
    BOARD = 0_i64..9_i64

    getter x : Int64
    getter y : Int64

    def initialize(@x : Int64, @y : Int64)
    end

    def self.corretto_draw(random : Random) : self
      new(Corretto::Property.whole(random, BOARD.begin, BOARD.end),
        Corretto::Property.whole(random, BOARD.begin, BOARD.end))
    end
  end

  # No part to share among: outside the domain of `Sums.per_part`.
  class NoParts < Exception
  end

  # An error whose message names what failed.
  class Unbalanced < Exception
  end

  module Sums
    alias Count = Int32

    # The classes drawn for the union argument of `total`.
    class_getter extras = Set(String).new

    def self.total(first : Count, rest : Array(Int64), extra : (Int32 | String)?) : Int64
      raise "#{rest.size} elements" if rest.size > Corretto::Property::ARRAY_MOST
      extras << extra.class.name
      rest.sum + first
    end

    def self.split(total : Int64, parts : Count) : Int64
      total // parts
    end

    def self.farthest(from : Point, others : Array(Point)) : Int64
      points = others + [from]
      raise "off the board" unless points.all?(&.x.in?(Point::BOARD))
      points.max_of(&.y)
    end

    def self.per_part(total : Int64, parts : Count) : Int64
      raise NoParts.new("nothing to share among") if parts <= 0
      total // parts
    end

    def self.root(square : Int64) : Float64
      raise Corretto::Property::Skip.new if square < 0
      Math.sqrt(square)
    end

    def self.nothing(count : Count) : Count
      raise Corretto::Property::Skip.new
    end

    def self.balance(debit : Int64, credit : Int64) : Int64
      raise Unbalanced.new("the books differ by #{debit - credit}") unless debit == credit
      debit
    end
  end

  # Functions a module holds by extending itself.
  module Doubling
    extend self

    def twice(count : Int32) : Int64
      count.to_i64 * 2
    end
  end
end

Corretto::Property.outside(PropertySpec::NoParts)
Corretto::Property.message_only(PropertySpec::Unbalanced)

# Runs the block with CORRETTO_SEED set to *seed*, then restores it.
private def seeded(seed : String, &)
  before = ENV["CORRETTO_SEED"]?
  ENV["CORRETTO_SEED"] = seed
  yield
ensure
  if before
    ENV["CORRETTO_SEED"] = before
  else
    ENV.delete("CORRETTO_SEED")
  end
end

private def failure_of_split : Spec::AssertionFailed
  expect_raises(Spec::AssertionFailed) do
    Corretto.property(PropertySpec::Sums.split)
  end
end

describe "Corretto.property" do
  it "runs a class method on 200 cases of whole numbers, an array and a union" do
    run = seeded("20261114") { Corretto.property(PropertySpec::Sums.total) }
    run.label.should eq("Sums.total")
    run.seed.should eq(20261114_u64)
    run.held.should eq(Corretto::Property::CASES)
    run.skipped.should eq(0)
    PropertySpec::Sums.extras.should eq(Set{"Int32", "String", "Nil"})
  end

  it "runs a method of a module that extends itself" do
    Corretto.property(PropertySpec::Doubling.twice).held.should eq(Corretto::Property::CASES)
  end

  it "fails on the first case that raises, naming the case, the seed and each argument" do
    failure = failure_of_split
    lines = failure.message.to_s.lines
    lines[0].should eq("Sums.split raised DivisionByZeroError: Division by 0")
    lines[1].should match(/\A  case \d+ of 200, seed (\d+); rerun with CORRETTO_SEED=\1\z/)
    lines[2].should match(/\A  total = -?\d+\z/)
    lines[3].should eq("  parts = 0")
    lines.size.should eq(4)
    failure.file.should eq(__FILE__)
  end

  it "fails the same way twice from the seed CORRETTO_SEED names" do
    messages = Array.new(2) { seeded("20261114") { failure_of_split.message.to_s } }
    messages[0].should eq(messages[1])
    messages[0].should contain("seed 20261114; rerun with CORRETTO_SEED=20261114")
  end

  it "draws a type from its own generator, alone and in an array" do
    run = Corretto.property(PropertySpec::Sums.farthest)
    run.held.should eq(Corretto::Property::CASES)
  end

  it "skips and counts a case that raises an exception named outside the domain" do
    run = Corretto.property(PropertySpec::Sums.per_part)
    run.skipped.should be > 0
    run.held.should eq(Corretto::Property::CASES - run.skipped)
  end

  it "skips and counts a case that raises Skip" do
    run = Corretto.property(PropertySpec::Sums.root)
    run.skipped.should be > 0
    run.held.should eq(Corretto::Property::CASES - run.skipped)
  end

  it "fails a run whose every case is skipped, which proves nothing" do
    expect_raises(Spec::AssertionFailed, /\ASums\.nothing refused every one of 200 cases/) do
      Corretto.property(PropertySpec::Sums.nothing)
    end
  end

  it "starts a failure with the message alone when the error says what failed" do
    failure = expect_raises(Spec::AssertionFailed) do
      Corretto.property(PropertySpec::Sums.balance)
    end
    failure.message.to_s.should start_with("the books differ by ")
  end
end
