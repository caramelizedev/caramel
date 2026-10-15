module App::Views::Sessions
  class New < App::ApplicationView
    def initialize(@csrf_token : String, @failed : Bool)
    end

    private def blueprint
      h1 { "Sign in" }
      p { "Email or password is wrong." } if @failed
      form method: "post", action: "/login", "hx-boost": "false" do
        input type: "hidden", name: "_csrf", value: @csrf_token
        label { "Email" }
        input type: "email", name: "email", required: true
        label { "Password" }
        input type: "password", name: "password", required: true
        button(type: "submit") { "Sign in" }
      end
    end
  end
end
