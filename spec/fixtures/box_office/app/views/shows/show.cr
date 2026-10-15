module App::Views::Shows
  class Show < App::ApplicationView
    def initialize(@show : App::BoxOffice::Seating::Show, @csrf_token : String)
    end

    private def blueprint
      section class: "show" do
        h1 { @show.title }
        p { @show.starts_at.to_s("%A %d %B %Y, %H:%M UTC") }
        p { "#{@show.left} of #{@show.capacity.to_i} seats left" }
        if @show.closed?
          p { "Sales for this show have closed." }
        elsif @show.left > 0
          seats_form("holds", "Hold seats")
        else
          seats_form("waitlist", "Join the waitlist")
        end
      end
    end

    private def seats_form(path : String, submit : String) : Nil
      form action: "/shows/#{@show.id.raw}/#{path}", method: "post" do
        input type: "hidden", name: "_csrf", value: @csrf_token
        label(for: "guest") { "Email" }
        input id: "guest", type: "email", name: "guest", required: true
        label(for: "seats") { "Seats" }
        input id: "seats", type: "number", name: "seats", value: "1", required: true
        button(type: "submit") { submit }
      end
    end
  end
end
