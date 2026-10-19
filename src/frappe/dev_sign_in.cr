require "http/client"
require "socket/unix_socket"
require "json"
require "./project"
require "./dev_gateway"
require "../latte/project_status"

module Caramel::Frappe
  # The link that signs a browser in to a running `frappe dev`. The gateway mints it
  # for the owner token in `dev-session.json`, which only this account can read.
  module DevSignIn
    TIMEOUT = 2.seconds
    LIMIT   = 4096

    # The single-use sign-in URL of the project's running `frappe dev`, or the bare
    # origin when none answers.
    def self.url(project : Project, directory : String) : String
      session = Latte::ProjectStatus.owner_session(directory) || return project.origin
      path = mint(URI.parse(project.origin), session) || return project.origin
      return project.origin unless path.starts_with?("#{DevGateway::SIGN_IN}?nonce=")

      project.origin + path
    rescue IO::Error | JSON::ParseException | KeyError | TypeCastError
      project.origin
    end

    private def self.mint(origin : URI, session : {socket: String, token: String}) : String?
      authority = origin.authority || return
      socket = Socket.unix
      socket.connect(Socket::UNIXAddress.new(session[:socket]), timeout: TIMEOUT)
      socket.read_timeout = TIMEOUT
      socket.write_timeout = TIMEOUT
      client = HTTP::Client.new(socket, origin.host || authority)
      headers = HTTP::Headers{
        "Host"                  => authority,
        "X-Caramel-Owner-Token" => session[:token],
        "Connection"            => "close",
      }
      client.get(DevGateway::SIGN_IN_LINK, headers) do |response|
        return unless response.status_code == 200

        JSON.parse(response.body_io.gets(LIMIT) || "")["path"].as_s
      end
    ensure
      client.try(&.close)
      socket.try(&.close)
    end
  end
end
