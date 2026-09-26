require "json"
require "http/server"
puts({"message" => "Caramel", "regex" => (/Caramel/ =~ "Caramel").to_s}.to_json)
