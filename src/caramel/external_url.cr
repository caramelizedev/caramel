require "uri"

module Caramel
  # The one rule for a URL that sends a browser or a request to another site,
  # shared by `Response.redirect_external`, `Outbound` and changesets'
  # `validate_url`: an absolute http or https URL with a host, and no
  # credentials, whitespace, control characters or backslashes.
  module ExternalURL
    def self.valid?(url : String) : Bool
      return false if url.each_char.any? { |char| char.ascii_whitespace? || char.ord < 32 || char.ord == 127 || char == '\\' }
      uri = URI.parse(url)
      {"http", "https"}.includes?(uri.scheme) && !uri.host.to_s.empty? && uri.user.nil?
    rescue URI::Error
      false
    end
  end
end
