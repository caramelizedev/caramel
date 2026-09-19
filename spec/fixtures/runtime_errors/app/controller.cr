module RuntimeErrorFixture
  def self.fail_request : Caramel::Response
    raise "Missing helper <unsafe> APP_SECRET=#{ENV["APP_SECRET"]} password=private-password #{ENV["DATABASE_URL"]}"
  end
end
