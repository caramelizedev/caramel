require "spec"
require "../../src/latte/collector"
require "../../src/latte/supervisor"

describe "Caramel::Latte.port_from" do
  it "returns the default when the variable is unset" do
    Caramel::Latte.port_from("CARAMEL_LATTE_DNS_PORT", 15353, value: nil).should eq 15353
  end

  it "parses a port from 1024 to 65535" do
    Caramel::Latte.port_from("CARAMEL_LATTE_HTTPS_PORT", 18443, value: "1024").should eq 1024
    Caramel::Latte.port_from("CARAMEL_LATTE_HTTPS_PORT", 18443, value: "65535").should eq 65535
  end

  it "refuses a privileged, out-of-range or non-numeric value, naming the variable" do
    ["0", "1023", "65536", "https", ""].each do |value|
      error = expect_raises(Caramel::Latte::PublicError) do
        Caramel::Latte.port_from("CARAMEL_LATTE_HTTP_PORT", 18080, value: value)
      end
      error.code.should eq "invalid_port"
      error.message.should eq(
        "CARAMEL_LATTE_HTTP_PORT must be a port from 1024 to 65535, not #{value.inspect}")
    end
  end

  it "lets the collector keep its 1..65535 range" do
    Caramel::Latte.port_from("CARAMEL_LATTE_OTLP_PORT", 4318, 1, "1").should eq 1
  end
end

describe Caramel::Latte::Supervisor do
  it "reads the three listener ports from the environment, 15353, 18080 and 18443 by default" do
    variables = {
      "CARAMEL_LATTE_DNS_PORT"   => ENV["CARAMEL_LATTE_DNS_PORT"]?,
      "CARAMEL_LATTE_HTTP_PORT"  => ENV["CARAMEL_LATTE_HTTP_PORT"]?,
      "CARAMEL_LATTE_HTTPS_PORT" => ENV["CARAMEL_LATTE_HTTPS_PORT"]?,
    }
    begin
      variables.each_key { |name| ENV.delete(name) }
      ports = Caramel::Latte::Supervisor.ports_from_environment
      ports.should eq({dns_port: 15353, http_port: 18080, https_port: 18443})
      ENV["CARAMEL_LATTE_DNS_PORT"] = "25353"
      ENV["CARAMEL_LATTE_HTTP_PORT"] = "28080"
      ENV["CARAMEL_LATTE_HTTPS_PORT"] = "28443"
      ports = Caramel::Latte::Supervisor.ports_from_environment
      ports.should eq({dns_port: 25353, http_port: 28080, https_port: 28443})
      ENV["CARAMEL_LATTE_HTTPS_PORT"] = "443"
      expect_raises(Caramel::Latte::PublicError, "CARAMEL_LATTE_HTTPS_PORT must be a port") do
        Caramel::Latte::Supervisor.ports_from_environment
      end
    ensure
      variables.each do |name, value|
        if value
          ENV[name] = value
        else
          ENV.delete(name)
        end
      end
    end
  end
end
