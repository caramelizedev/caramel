module App::Views::@@COLLECTION@@
  class Show < App::ApplicationView
    def initialize(@record : App::@@MODEL@@, @csrf_token : String)
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
        h1 { t.@@PLURAL@@.model }
        # frappe:else
        h1 { "@@MODEL@@" }
        # frappe:end
        dl do
@@SHOW_FIELDS@@
        end
        # frappe:only edit,destroy
        div class: "actions" do
          # frappe:only edit
          # frappe:only locales
          a(class: "button", href: edit_@@SINGULAR@@_path(@record.id)) { t.@@PLURAL@@.edit_record }
          # frappe:else
          a(class: "button", href: edit_@@SINGULAR@@_path(@record.id)) { "Edit @@LABEL@@" }
          # frappe:end
          # frappe:end
          # frappe:only destroy
          form action: @@SINGULAR@@_path(@record.id), method: "post" do
            input type: "hidden", name: "_csrf", value: @csrf_token
            input type: "hidden", name: "_method", value: "DELETE"
            # frappe:only locales
            button(class: "danger", type: "submit") { t.@@PLURAL@@.delete_record }
            # frappe:else
            button(class: "danger", type: "submit") { "Delete @@LABEL@@" }
            # frappe:end
          end
          # frappe:end
        end
        # frappe:end
      end
    end
  end
end
