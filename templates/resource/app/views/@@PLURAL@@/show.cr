module App::Views::@@COLLECTION@@
  class Show < App::ApplicationView
    def initialize(@record : App::@@MODEL@@, @csrf_token : String)
    end

    private def blueprint
      a(class: "back", href: @@PLURAL@@_path) { "← @@COLLECTION_LABEL@@" } # frappe:only=index
      section class: "form-page" do
        h1 { "@@MODEL@@" }
        dl do
@@SHOW_FIELDS@@
        end
        div class: "actions" do # frappe:only=edit,destroy
          a(class: "button", href: edit_@@SINGULAR@@_path(@record.id)) { "Edit @@LABEL@@" } # frappe:only=edit
          form action: @@SINGULAR@@_path(@record.id), method: "post" do # frappe:only=destroy
            input type: "hidden", name: "_csrf", value: @csrf_token # frappe:only=destroy
            input type: "hidden", name: "_method", value: "DELETE" # frappe:only=destroy
            button(class: "danger", type: "submit") { "Delete @@LABEL@@" } # frappe:only=destroy
          end # frappe:only=destroy
        end # frappe:only=edit,destroy
      end
    end
  end
end
