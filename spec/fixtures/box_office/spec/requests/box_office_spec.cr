require "../spec_helper"

describe "The box office" do
  it "holds seats, sells them, and offers the waitlist once the show is sold out" do
    Corretto.session do |client, _db|
      show = App::BoxOffice::Seating::Show.schedule("The Tempest",
        Time.utc(2026, 11, 20, 19, 30), App::BoxOffice::Seating::Capacity.new(2))
      path = "/shows/#{show.id.raw}"
      client.get(path).should have_html {
        section(class: "show") { button(type: "submit") { "Hold seats" } }
      }
      held = client.post("#{path}/holds", params: {"guest" => "ada@example.com", "seats" => "2"})
      held.should redirect_to("#{path}/holds/1")
      client.follow_redirect.should have_html {
        section(class: "hold") { button(type: "submit") { "Pay for the seats" } }
      }
      client.get(path).should have_html {
        section(class: "show") { button(type: "submit") { "Join the waitlist" } }
      }
      client.post("#{path}/holds/1/sale").should redirect_to("#{path}/holds/1")
      client.follow_redirect.should have_html {
        section(class: "hold") { p { "Paid: 2 seats. The tickets go to ada@example.com." } }
      }
    end
  end

  it "answers 422 for a refusal or a bad value, and 404 for a show that is not a number" do
    Corretto.session do |client, _db|
      show = App::BoxOffice::Seating::Show.schedule("The Tempest",
        Time.utc(2026, 11, 20, 19, 30), App::BoxOffice::Seating::Capacity.new(1))
      show.hold(App::BoxOffice::Seating::Email.new("ada@example.com"),
        App::BoxOffice::Seating::Seats.new(1))
      path = "/shows/#{show.id.raw}/holds"
      json = {"Accept" => "application/json"}
      sold_out = client.post(path, headers: json,
        params: {"guest" => "bo@example.com", "seats" => "1"})
      sold_out.should have_status(422)
      sold_out.body.should eq(%({"errors":{"_base":["The Tempest is sold out."]}}))
      too_many = client.post(path, headers: json,
        params: {"guest" => "bo@example.com", "seats" => "9"})
      too_many.should have_status(422)
      too_many.body.should eq(%({"errors":{"seats":["Seats must be between 1 and 8"]}}))
      stray = client.post("/shows/abc/holds",
        params: {"guest" => "bo@example.com", "seats" => "1"})
      stray.should have_status(404)
    end
  end
end
