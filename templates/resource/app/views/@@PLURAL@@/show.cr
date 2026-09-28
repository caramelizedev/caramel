module App::Views::@@COLLECTION@@
  class Show < App::ApplicationView
    def initialize(@record : App::@@MODEL@@, @csrf_token : String)
    end

    private def blueprint
      a(class: "back", href: @@PLURAL@@_path) { "← @@COLLECTION_LABEL@@" }
      section class: "form-page" do
        h1 { "@@MODEL@@" }
        dl do
@@SHOW_FIELDS@@
        end
        div class: "actions" do
          a(class: "button", href: edit_@@SINGULAR@@_path(@record.id)) { "Edit @@LABEL@@" }
          form action: @@SINGULAR@@_path(@record.id), method: "post" do
            input type: "hidden", name: "_csrf", value: @csrf_token
            input type: "hidden", name: "_method", value: "DELETE"
            button(class: "danger", type: "submit") { "Delete @@LABEL@@" }
          end
        end
      end
    end
  end
end
