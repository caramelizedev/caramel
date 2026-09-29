module App::Views::@@COLLECTION@@
  class New < App::ApplicationView
    def initialize(@form : Form)
    end

    private def blueprint
      a(class: "back", href: @@PLURAL@@_path) { "← @@COLLECTION_LABEL@@" } # frappe:only=index
      section class: "form-page" do
        h1 { "New @@LABEL@@" }
        render @form
      end
    end
  end
end
