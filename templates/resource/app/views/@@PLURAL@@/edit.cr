module App::Views::@@COLLECTION@@
  class Edit < App::ApplicationView
    def initialize(@id : Int64, @form : Form)
    end

    private def blueprint
      a(class: "back", href: @@SINGULAR@@_path(@id)) { "← Back to @@LABEL@@" }
      section class: "form-page" do
        h1 { "Edit @@LABEL@@" }
        render @form
      end
    end
  end
end
