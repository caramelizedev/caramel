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

struct ArrayContract < Caramel::RequestContract
  field ids : Array(Int64), min: 1, max: 3
  field tags : Array(String), max: 2
end

private def input(body : String,
                  method = "POST",
                  path = "/teams",
                  route = {} of String => String) : Caramel::RequestInput
  headers = HTTP::Headers{"Content-Type" => "application/x-www-form-urlencoded"}
  request = HTTP::Request.new(method, path, headers, body)
  Caramel::RequestInput.read(request).tap(&.route_params=(route))
end

private def json_input(body : String,
                       route = {} of String => String) : Caramel::RequestInput
  headers = HTTP::Headers{"Content-Type" => "application/json"}
  request = HTTP::Request.new("POST", "/teams", headers, body)
  Caramel::RequestInput.read(request).tap(&.route_params=(route))
end

describe Caramel::RequestContract do
  it "binds a JSON object whose members have their fields' JSON types" do
    contract = ScalarContract.parse(json_input(<<-JSON))
      {
        "count": -23,
        "total": 9223372036854775807,
        "active": false,
        "score": 1.5e1,
        "published_at": "2026-09-19T14:30:00+02:00",
        "note": null
      }
      JSON
    contract.valid?.should be_true
    contract.count.should eq(-23)
    contract.total.should eq(Int64::MAX)
    contract.active.should be_false
    contract.score.should eq(15.0)
    contract.note.should be_nil
    contract.published_at.should eq(Time.utc(2026, 9, 19, 12, 30))

    team_body = %({"seats": 3, "name": "Owls", "plan": null})
    team = TeamContract.parse(json_input(team_body, {"id" => "7"}))
    team.valid?.should be_true
    {team.id, team.plan, team.archived}.should eq({7_i64, "free", false})
  end

  it "refuses mistyped and unknown JSON members, and a body that is not an object" do
    contract = ScalarContract.parse(json_input(<<-JSON))
      {
        "count": "5",
        "total": 1.5,
        "active": "true",
        "score": true,
        "published_at": 1,
        "note": ["x"],
        "extra": null
      }
      JSON
    contract.errors.should eq({
      "count"        => ["must be a JSON number"],
      "total"        => ["must be a valid Int64"],
      "active"       => ["must be a JSON boolean"],
      "score"        => ["must be a JSON number"],
      "published_at" => ["must be a JSON string"],
      "note"         => ["must be a JSON string"],
      "_base"        => ["Unknown field: extra"],
    })

    twice = %({"count": 1, "total": 1, "active": true, "total": 2})
    duplicated = ScalarContract.parse(json_input(twice))
    duplicated.errors["_base"].should eq(["Duplicate field: total"])
    listed = ScalarContract.parse(json_input("[1]"))
    listed.errors["_base"].should contain("Expected a JSON object")
    named = AvatarContract.parse(json_input(%({"avatar": "me.png"})))
    named.errors["avatar"].should eq(["must be a file"])

    # A route parameter counts as a member.
    body = %({"id": 8, "seats": 3, "name": "Owls"})
    routed = TeamContract.parse(json_input(body, {"id" => "7"}))
    routed.errors["_base"].should eq(["Duplicate field: id"])
  end

  it "parses the documented scalar grammar and treats blank nilable fields as nil" do
    body = "count=-23&total=9223372036854775807&active=false&score=&note=+"
    contract = ScalarContract.parse(input(body))
    contract.valid?.should be_true
    contract.count.should eq(-23)
    contract.total.should eq(Int64::MAX)
    contract.active.should be_false
    contract.score.should be_nil
    contract.published_at.should be_nil
    contract.note.should be_nil
  end

  it "accepts finite floats and RFC 3339 timestamps with an explicit zone" do
    required = "count=0&total=0&active=true"
    zoned = "2026-09-19T14%3A30%3A00%2B02%3A00"
    contract = ScalarContract.parse(input("#{required}&score=1.25&published_at=#{zoned}"))
    contract.valid?.should be_true
    contract.score.should eq(1.25)
    contract.published_at.should eq(Time.utc(2026, 9, 19, 12, 30))
    ["1_000", "1.5", "0x10", " 5 "].each do |bad|
      count = URI.encode_www_form(bad)
      contract = ScalarContract.parse(input("count=#{count}&total=0&active=true"))
      contract.errors["count"].should eq(["must be a valid Int32"])
    end
    ["Infinity", "-Infinity", "1e999", "1_000"].each do |bad|
      rejected = ScalarContract.parse(input("#{required}&score=#{bad}"))
      rejected.errors["score"].should eq(["must be a valid Float64"])
    end
    ["2026-09-19T14:30:00", "yesterday"].each do |bad|
      stamp = URI.encode_www_form(bad)
      rejected = ScalarContract.parse(input("#{required}&published_at=#{stamp}"))
      rejected.errors["published_at"].should eq(["must be a valid Time"])
    end
  end

  it "reports every error and keeps the submitted text" do
    contract = ScalarContract.parse(input("count=2147483648&total=&active=yes"))
    contract.valid?.should be_false
    contract.errors.should eq({
      "count"  => ["must be a valid Int32"],
      "total"  => ["is required"],
      "active" => ["must be a valid Bool"],
    })
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
    unknown = ScalarContract.parse(input("count=1&total=1&active=true&x=1"))
    unknown.errors["_base"].should eq(["Unknown field: x"])
    query = "/scalars?count=1&total=1&active=true&utm_source=mail"
    get = Caramel::RequestInput.read(HTTP::Request.new("GET", query))
    ScalarContract.parse(get).valid?.should be_true
  end

  it "refuses a field supplied by more than one source" do
    contract = TeamContract.parse(input("id=8&seats=3&name=Owls", route: {"id" => "7"}))
    contract.errors["_base"].should eq(["Duplicate field: id"])
    contract.route_error?(["id"]).should be_false
  end

  it "binds bounded array fields from repeated keys and JSON arrays" do
    form = ArrayContract.parse(input("ids=1&ids=2&tags=a"))
    form.errors.should be_empty
    form.ids.should eq([1_i64, 2_i64])
    form.tags.should eq(["a"])
    form.lists["ids"].should eq(%w[1 2])

    json = ArrayContract.parse(json_input(%({"ids":[1,2],"tags":null})))
    json.errors.should be_empty
    json.ids.should eq([1_i64, 2_i64])
    json.tags.should be_empty

    ArrayContract.parse(input("ids=1")).tags.should be_empty
  end

  it "reports array bounds, items and sources" do
    ArrayContract.parse(input("")).errors.should eq({"ids" => ["must have at least 1 item(s)"]})
    too_many = ArrayContract.parse(input("ids=1&ids=2&ids=3&ids=4"))
    too_many.errors.should eq({"ids" => ["must have at most 3 item(s)"]})
    ArrayContract.parse(input("ids=1&tags=a&tags=b&tags=c")).errors.should eq({
      "tags" => ["must have at most 2 item(s)"],
    })
    ArrayContract.parse(input("ids=1&ids=x")).errors.should eq({
      "ids[1]" => ["must be a valid Int64"],
    })
    ArrayContract.parse(input("ids=1&ids=1")).errors.should eq({
      "ids[1]" => ["repeats an earlier item"],
    })
    ArrayContract.parse(input("ids=1&ids=")).errors.should eq({"ids[1]" => ["is required"]})
    ArrayContract.parse(json_input(%({"ids":["1"]}))).errors.should eq({
      "ids[0]" => ["must be a JSON number"],
    })
    ArrayContract.parse(json_input(%({"ids":[null]}))).errors.should eq({
      "ids[0]" => ["is required"],
    })
    ArrayContract.parse(json_input(%({"ids":5}))).errors.should eq({
      "ids" => ["must be a JSON array"],
    })
    both = input("ids=2", path: "/teams?ids=1")
    ArrayContract.parse(both).errors.should eq({"_base" => ["Duplicate field: ids"]})
    ArrayContract.parse(input("ids=1&other=1")).errors.should eq({
      "_base" => ["Unknown field: other"],
    })
    ArrayContract.parse(input("ids=1&_csrf=a&_csrf=b")).errors.should eq({
      "_base" => ["Duplicate field: _csrf"],
    })
    contract = ArrayContract.parse(input("ids=1&ids=x"))
    contract.lists["ids"].should eq(%w[1 x])
  end

  it "keeps a repeated scalar name a duplicate" do
    contract = TeamContract.parse(input("id=8&seats=3&name=Owls&name=Cats"))
    contract.errors["_base"].should eq(["Duplicate field: name"])
  end

  it "binds uploaded files from multipart forms and refuses text in their place" do
    io = IO::Memory.new
    form = HTTP::FormData::Builder.new(io, "caramel-boundary")
    metadata = HTTP::FormData::FileMetadata.new(filename: "me.png")
    form.file("avatar", IO::Memory.new("png"), metadata)
    form.finish
    headers = HTTP::Headers{"Content-Type" => form.content_type}
    request = HTTP::Request.new("POST", "/avatars", headers, io.to_s)
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
    contract.to_mrdp("POST", "/teams").should eq(<<-MRDP + "\n")
      ERR CONTRACT_INVALID:422 at POST /teams
      FIELD seats: must be at least 1
      MRDP
  end
end
