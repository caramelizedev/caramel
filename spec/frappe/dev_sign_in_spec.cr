require "spec"
require "file_utils"
require "../../src/latte/registry"
require "../../src/latte/project_status"
require "../../src/frappe/dev_gateway"
require "../../src/frappe/dev_sign_in"

private HOST = HTTP::Headers{"Host" => "bookshelf.caramel"}

private MANIFEST = <<-YAML
  version: 1
  name: bookshelf
  postgresql_major: 18
  extensions: []
  domain_suffix: caramel
  YAML

private def project_at(root : String) : Caramel::Frappe::Project
  manifest = Caramel::Frappe::EnvironmentManifest.from_yaml(MANIFEST)
  Caramel::Frappe::Project.new(root, manifest)
end

# Serves *gateway* on a socket in a Latte run directory and writes its session file.
private def serving(gateway : Caramel::Frappe::DevGateway,
                    directory : String) : HTTP::Server
  socket = File.join(directory, "dev-sign-in.sock")
  server = HTTP::Server.new([gateway])
  server.bind_unix(socket)
  File.chmod(socket, 0o600)
  spawn { server.listen }
  Caramel::Latte::ProjectStatus.write_session(directory, socket, gateway.owner_token)
  server
end

describe Caramel::Frappe::DevSignIn do
  it "returns a link under the project origin that signs a browser in once" do
    root = "/private/tmp/caramel-sign-in-#{Random::Secure.hex(6)}"
    Dir.mkdir(root, 0o700)
    paths = Caramel::Latte::Paths.new(root)
    # ameba:disable Lint/UselessAssign -- read by the ensure below
    server : HTTP::Server? = nil
    begin
      site = Caramel::Latte::Registry.new(paths).register("bookshelf", root)
      directory = paths.site_run_dir(site.id)
      project = project_at(root)
      gateway = Caramel::Frappe::DevGateway.new(project.origin)
      server = serving(gateway, directory)
      url = Caramel::Frappe::DevSignIn.url(project, directory)
      url.should start_with("#{project.origin}/__caramel/dev/sign-in?nonce=")
      target = URI.parse(url).request_target
      signed = gateway.handle(HTTP::Request.new("GET", target, HOST))
      signed.status.should eq(303)
      signed.headers["Set-Cookie"].should contain("__Host-caramel_dev=")
      gateway.handle(HTTP::Request.new("GET", target, HOST)).status.should eq(403)
    ensure
      server.try { |item| item.close unless item.closed? }
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end

  it "returns the bare origin with no session file, a dead socket or a wrong owner token" do
    root = "/private/tmp/caramel-sign-in-#{Random::Secure.hex(6)}"
    Dir.mkdir(root, 0o700)
    paths = Caramel::Latte::Paths.new(root)
    # ameba:disable Lint/UselessAssign -- read by the ensure below
    server : HTTP::Server? = nil
    begin
      site = Caramel::Latte::Registry.new(paths).register("bookshelf", root)
      directory = paths.site_run_dir(site.id)
      project = project_at(root)
      Caramel::Frappe::DevSignIn.url(project, directory).should eq(project.origin)

      gateway = Caramel::Frappe::DevGateway.new(project.origin)
      server = serving(gateway, directory)
      socket = File.join(directory, "dev-sign-in.sock")
      stranger = "f" * 64
      Caramel::Latte::ProjectStatus.write_session(directory, socket, stranger)
      Caramel::Frappe::DevSignIn.url(project, directory).should eq(project.origin)

      Caramel::Latte::ProjectStatus.write_session(directory, socket, gateway.owner_token)
      server.close
      File.delete?(socket)
      Caramel::Frappe::DevSignIn.url(project, directory).should eq(project.origin)
    ensure
      server.try { |item| item.close unless item.closed? }
      FileUtils.rm_rf(paths.run_dir)
      FileUtils.rm_rf(root)
    end
  end
end
