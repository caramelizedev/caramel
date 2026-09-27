require "../../../src/caramel/response"

response = Caramel::Response.new(status: 204)
puts response.status
