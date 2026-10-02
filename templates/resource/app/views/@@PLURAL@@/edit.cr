module App::Views::@@COLLECTION@@
  class Edit < App::ApplicationView
    def initialize(@id : Int64, @form : Form)
    end

    private def blueprint
      # frappe:only locales
      a(class: "back", href: @@SINGULAR@@_path(@id)) { t.@@PLURAL@@.back_to_record }
      # frappe:else
      a(class: "back", href: @@SINGULAR@@_path(@id)) { "← Back to @@LABEL@@" }
      # frappe:end
      section class: "form-page" do
        # frappe:only locales
        h1 { t.@@PLURAL@@.edit_record }
        # frappe:else
        h1 { "Edit @@LABEL@@" }
        # frappe:end
        render @form
      end
    end
  end
end
