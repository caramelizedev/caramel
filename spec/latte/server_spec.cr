require "spec"
require "file_utils"
require "../../src/latte/server"

private class TestServices < Caramel::Latte::ServiceControl
  getter starts = 0
  getter stops = 0

  def initialize(@registry : Caramel::Latte::Registry)
  end

  def status_json : String
    %({"version":1,"services":{"postgres":{"state":"stopped"},"dns":{"state":"stopped"},"proxy":{"state":"stopped"}}})
  end

  def start_services : Nil
    @starts += 1
  end

  def stop_services : Nil
    @stops += 1
  end

  def register(name : String, directory : String, suffix : String) : Caramel::Latte::Site
    @registry.register(name, directory, suffix)
  end

  def unregister(id : String) : Bool
    !@registry.unregister(id).nil?
  end

  def set_upstream(id : String, socket : String) : Caramel::Latte::Site
    @registry.set_upstream(id, socket)
  end
end

describe Caramel::Latte::Server do
  it "refuses service mutations after the request budget expires" do
    root = File.join("/private/tmp", "latte-api-deadline-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      services = TestServices.new(registry)
      server = Caramel::Latte::Server.new(registry, services)
      request = HTTP::Request.new("POST", "/v1/services/start", HTTP::Headers{"Content-Type" => "application/json"}, "{}")
      Caramel::Latte::OperationDeadline.run(1.millisecond) do
        sleep 5.milliseconds
        server.handle(request).status.should eq(503)
      end
      services.starts.should eq(0)
    ensure
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "shares a versioned site/service API and bounds mutations" do
    root = File.join("/private/tmp", "latte-api-#{Random::Secure.hex(8)}")
    Dir.mkdir(root, 0o700)
    registry = Caramel::Latte::Registry.new(root)
    begin
      services = TestServices.new(registry)
      server = Caramel::Latte::Server.new(registry, services)
      headers = HTTP::Headers{"Content-Type" => "application/json"}
      response = server.handle(HTTP::Request.new("POST", "/v1/sites", headers, {name: "bookshelf", directory: root}.to_json))
      response.status.should eq(201)
      site = JSON.parse(response.body)["site"]
      site["origin"].as_s.should eq("https://bookshelf.caramel")
      site["domain"].as_s.should eq("bookshelf.caramel")
      JSON.parse(server.handle(HTTP::Request.new("GET", "/v1/sites")).body)["sites"].as_a.size.should eq(1)
      server.handle(HTTP::Request.new("POST", "/v1/services/start", headers, "{}")).status.should eq(200)
      services.starts.should eq(1)
      server.handle(HTTP::Request.new("POST", "/v1/services/stop", headers, "{}")).status.should eq(200)
      services.stops.should eq(1)
      server.handle(HTTP::Request.new("POST", "/v1/services/start", headers, "{" + " " * 16384)).status.should eq(413)
      services.starts.should eq(1)
      server.handle(HTTP::Request.new("POST", "/v1/services/start", headers, %({"extra":true}))).status.should eq(400)
      server.handle(HTTP::Request.new("POST", "/v1/sites", headers, %({"name":"bad","directory":"/missing","admin":true}))).status.should eq(400)
      server.handle(HTTP::Request.new("POST", "/v1/sites", HTTP::Headers.new, "{}")).status.should eq(415)
      server.handle(HTTP::Request.new("DELETE", "/v1/sites/#{site["id"].as_s}")).status.should eq(200)
      Dir.exists?(root).should be_true
      registry.list.should be_empty
      server.handle(HTTP::Request.new("GET", "/unknown")).status.should eq(404)
    ensure
      FileUtils.rm_rf(registry.paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end
end
