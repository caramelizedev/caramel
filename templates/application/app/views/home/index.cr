module App::Views::Home
  class Index < App::ApplicationView
    private def blueprint
      section class: "heading" do
        div do
          p(class: "eyebrow") { "YOUR NEXT IDEA STARTS HERE" }
          h1 do
            plain "A little less setup."
            br
            plain "A lot more possibility."
          end
          p(class: "lede") { "#{App::TITLE} is ready for its first feature." }
        end
        span(class: "welcome-seal", aria_hidden: "true") { "c." }
      end
      section class: "welcome-grid", aria_label: "Start building" do
        step "01", "Make a feature", "Create a model, pages, and forms together.", "frappe make resource Book title:string author:string"
        step "02", "Apply your migration", "Keep database changes explicit and versioned.", "frappe migrate"
        step "03", "Make it yours", "Your files are ordinary Crystal and CSS.", "frappe corretto"
      end
    end

    private def step(number : String, heading : String, text : String, command : String) : Nil
      article class: "welcome-card" do
        span(class: "step") { number }
        h2 { heading }
        p { text }
        pre { code { command } }
      end
    end
  end
end
