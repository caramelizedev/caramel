require "json"
require "http/server"
require "big"
puts({"message" => "Caramel", "regex" => (/Caramel/ =~ "Caramel").to_s,
      "decimal" => (BigDecimal.new("0.1") + BigDecimal.new("0.2")).to_s}.to_json)
