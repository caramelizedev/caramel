require "spec"
require "../../src/caramel"

struct ScalarContract < Caramel::RequestContract
  field count : Int32
  field total : Int64
  field active : Bool
  field score : Float64?
  field published_at : Time?
  field note : String?
end

struct TeamContract < Caramel::RequestContract
  field id : Int64, min: 1
  field seats : Int32, min: 1, max: 50
  field name : String, min: 2, max: 5
  field plan : String, default: "free"
  field archived : Bool, default: false
end

struct AvatarContract < Caramel::RequestContract
  field avatar : Caramel::UploadedFile
  field caption : String?
end

private def input(body : String, method = "POST", path = "/teams", route = {} of String => String) : Caramel::RequestInput
  headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
  Caramel::RequestInput.read(HTTP::Request.new(method, path, headers, body)).tap(&.route_params=(route))
end

private def json_input(body : String, route = {} of String => String) : Caramel::RequestInput
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  Caramel::RequestInput.read(HTTP::Request.new("POST", "/teams", headers, body)).tap(&.route_params=(route))
end

describe Caramel::RequestContract do
  it "binds a JSON object whose members have their fields' JSON types" do
    contract = ScalarContract.parse(json_input(%({"count": -23, "total": 9223372036854775807, "active": false, "score": 1.5e1, "published_at": "2026-09-19T14:30:00+02:00", "note": null})))
    contract.valid?.should be_true
    {contract.count, contract.total, contract.active, contract.score, contract.note}.should eq({-23, Int64::MAX, false, 15.0, nil})
    contract.published_at.should eq(Time.utc(2026, 9, 19, 12, 30))
    team = TeamContract.parse(json_input(%({"seats": 3, "name": "Owls", "plan": null}), {"id" => "7"}))
    team.valid?.should be_true
    {team.id, team.plan, team.archived}.should eq({7_i64, "free", false})
  end

  it "refuses JSON members of the wrong type, unknown members and a body that is not an object" do
    contract = ScalarContract.parse(json_input(%({"count": "5", "total": 1.5, "active": "true", "score": true, "published_at": 1, "note": ["x"], "extra": null})))
    contract.errors.should eq({
      "count"        => ["must be a JSON number"],
      "total"        => ["must be a valid Int64"],
      "active"       => ["must be a JSON boolean"],
      "score"        => ["must be a JSON number"],
      "published_at" => ["must be a JSON string"],
      "note"         => ["must be a JSON string"],
      "_base"        => ["Unknown field: extra"],
    })
    ScalarContract.parse(json_input(%({"count": 1, "total": 1, "active": true, "total": 2}))).errors["_base"].should eq(["Duplicate field: total"])
    ScalarContract.parse(json_input("[1]")).errors["_base"].should contain("Expected a JSON object")
    AvatarContract.parse(json_input(%({"avatar": "me.png"}))).errors["avatar"].should eq(["must be a file"])
    TeamContract.parse(json_input(%({"id": 8, "seats": 3, "name": "Owls"}), {"id" => "7"})).errors["_base"].should eq(["Duplicate field: id"])
  end

  it "parses the documented scalar grammar and treats blank nilable fields as nil" do
    contract = ScalarContract.parse(input("count=-23&total=9223372036854775807&active=false&score=&note=+"))
    contract.valid?.should be_true
    contract.count.should eq(-23)
    contract.total.should eq(Int64::MAX)
    contract.active.should be_false
    contract.score.should be_nil
    contract.published_at.should be_nil
    contract.note.should be_nil
  end

  it "accepts finite floats and RFC 3339 timestamps with an explicit zone" do
    contract = ScalarContract.parse(input("count=0&total=0&active=true&score=1.25&published_at=2026-09-19T14%3A30%3A00%2B02%3A00"))
    contract.valid?.should be_true
    contract.score.should eq(1.25)
    contract.published_at.should eq(Time.utc(2026, 9, 19, 12, 30))
    ["1_000", "1.5", "0x10", " 5 "].each do |bad|
      contract = ScalarContract.parse(input("count=#{URI.encode_www_form(bad)}&total=0&active=true"))
      contract.errors["count"].should eq(["must be a valid Int32"])
    end
    ["Infinity", "-Infinity", "1e999", "1_000"].each do |bad|
      ScalarContract.parse(input("count=0&total=0&active=true&score=#{bad}")).errors["score"].should eq(["must be a valid Float64"])
    end
    ["2026-09-19T14:30:00", "yesterday"].each do |bad|
      ScalarContract.parse(input("count=0&total=0&active=true&published_at=#{URI.encode_www_form(bad)}")).errors["published_at"].should eq(["must be a valid Time"])
    end
  end

  it "reports every error and keeps the submitted text" do
    contract = ScalarContract.parse(input("count=2147483648&total=&active=yes"))
    contract.valid?.should be_false
    contract.errors.should eq({"count" => ["must be a valid Int32"], "total" => ["is required"], "active" => ["must be a valid Bool"]})
    contract.values.should eq({"count" => "2147483648", "total" => "", "active" => "yes"})
  end

  it "applies defaults and numeric and length bounds" do
    contract = TeamContract.parse(input("seats=3&name=Owls", route: {"id" => "7"}))
    contract.valid?.should be_true
    contract.plan.should eq("free")
    contract.archived.should be_false
    invalid = TeamContract.parse(input("seats=0&name=Barn+Owls&plan=pro", route: {"id" => "0"}))
    invalid.errors.should eq({
      "id"    => ["must be at least 1"],
      "seats" => ["must be at least 1"],
      "name"  => ["must be at most 5 characters"],
    })
    TeamContract.parse(input("seats=51&name=O", route: {"id" => "7"})).errors.should eq({
      "seats" => ["must be at most 50"],
      "name"  => ["must be at least 2 characters"],
    })
  end

  it "rejects undeclared body keys but ignores unrelated GET query keys" do
    ScalarContract.parse(input("count=1&total=1&active=true&x=1")).errors["_base"].should eq(["Unknown field: x"])
    get = Caramel::RequestInput.read(HTTP::Request.new("GET", "/scalars?count=1&total=1&active=true&utm_source=mail"))
    ScalarContract.parse(get).valid?.should be_true
  end

  it "refuses a field supplied by more than one source" do
    contract = TeamContract.parse(input("id=8&seats=3&name=Owls", route: {"id" => "7"}))
    contract.errors["_base"].should eq(["Duplicate field: id"])
    contract.route_error?(["id"]).should be_false
  end

  it "binds uploaded files from multipart forms and refuses text in their place" do
    io = IO::Memory.new
    form = HTTP::FormData::Builder.new(io, "caramel-boundary")
    form.file("avatar", IO::Memory.new("png"), HTTP::FormData::FileMetadata.new(filename: "me.png"))
    form.finish
    request = HTTP::Request.new("POST", "/avatars", HTTP::Headers{"Content-Type" => form.content_type}, io.to_s)
    multipart = Caramel::RequestInput.read(request)
    begin
      contract = AvatarContract.parse(multipart)
      contract.valid?.should be_true
      contract.avatar.filename.should eq("me.png")
      contract.caption.should be_nil
    ensure
      multipart.cleanup
    end
    AvatarContract.parse(input("avatar=me.png")).errors["avatar"].should eq(["must be a file"])
    AvatarContract.parse(input("")).errors["avatar"].should eq(["is required"])
  end

  it "renders machine-readable diagnostics" do
    contract = TeamContract.parse(input("seats=0&name=Owls", route: {"id" => "7"}))
    contract.to_mrdp("POST", "/teams").should eq("ERR CONTRACT_INVALID:422 at POST /teams\nFIELD seats: must be at least 1\n")
  end
end
