module App::Views::Holds
  class Show < App::ApplicationView
    def initialize(@show : BoxOffice::Seating::Show, @number : Int32, @csrf_token : String)
    end

    private def blueprint
      section class: "hold" do
        h1 { @show.title }
        if hold = @show.holds.find { |kept| kept.number == @number }
          due = hold.expires_at.to_s("%H:%M")
          p { "#{hold.seats.to_i} seats held for #{hold.guest.raw} until #{due} UTC." }
          form action: "/shows/#{@show.id.raw}/holds/#{@number}/sale", method: "post" do
            input type: "hidden", name: "_csrf", value: @csrf_token
            button(type: "submit") { "Pay for the seats" }
          end
        elsif ticket = @show.tickets.find { |sold| sold.number == @number }
          p { "Paid: #{ticket.seats.to_i} seats. The tickets go to #{ticket.guest.raw}." }
        else
          p { "This hold has ended, and its seats went back on sale." }
          a(href: "/shows/#{@show.id.raw}") { "Back to #{@show.title}" }
        end
      end
    end
  end
end
