module App::Views::@@COLLECTION@@
  class Form < App::ApplicationView
    def initialize(@action : String, @csrf_token : String, @values : Hash(String, String), @errors : Hash(String, Array(String)))
    end

    private def blueprint
      form class: "book-form", action: @action, method: "post" do
        input type: "hidden", name: "_csrf", value: @csrf_token
        error_summary unless @errors.empty?
        labelled "name", "Name" do |id|
          input type: "text", id: id, name: "name", required: true, aria_describedby: "#{id}_errors", aria_invalid: @errors.has_key?("name").to_s, value: @values["name"]? || ""
        end
        labelled "slug", "Slug" do |id|
          input type: "text", id: id, name: "slug", required: true, aria_describedby: "#{id}_errors", aria_invalid: @errors.has_key?("slug").to_s, value: @values["slug"]? || ""
        end
        div class: "actions" do
          button(class: "button", type: "submit") { "Save @@LABEL@@" }
          a(class: "cancel", href: "/") { "Cancel" }
        end
      end
    end

    private def error_summary : Nil
      div class: "errors", role: "alert", tabindex: "-1", id: "form-errors" do
        p { "Please check the fields below." }
        ul do
          @errors.each do |field, messages|
            messages.each { |message| li { field == "_base" ? message : "#{field}: #{message}" } }
          end
        end
      end
    end

    # A field's label, the control the block writes, and the field's errors.
    private def labelled(name : String, text : String, &) : Nil
      id = "@@SINGULAR@@_#{name}"
      label(for: id) { text }
      yield id
      div id: "#{id}_errors" do
        (@errors[name]? || [] of String).each { |error| p(class: "field-error") { error } }
      end
    end
  end
end
