module App::Views::@@COLLECTION@@
  class New < App::ApplicationView
    def initialize(@form : Form)
    end

    private def blueprint
      # frappe:only index
      # frappe:only locales
      a(class: "back", href: @@PLURAL@@_path) { t.@@PLURAL@@.back_to_collection }
      # frappe:else
      a(class: "back", href: @@PLURAL@@_path) { "← @@COLLECTION_LABEL@@" }
      # frappe:end
      # frappe:end
      section class: "form-page" do
        # frappe:only locales
        h1 { t.@@PLURAL@@.new_record }
        # frappe:else
        h1 { "New @@LABEL@@" }
        # frappe:end
        render @form
      end
    end
  end
end
