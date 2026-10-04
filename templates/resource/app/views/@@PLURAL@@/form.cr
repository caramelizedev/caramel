module App::Views::@@COLLECTION@@
  class Form < App::ApplicationView
    def initialize(@action : String, @method : String, @csrf_token : String, @values : Hash(String, String), @errors : Hash(String, Array(String)))
    end

    private def blueprint
      form class: "book-form", action: @action, method: "post" do
        input type: "hidden", name: "_csrf", value: @csrf_token
        input type: "hidden", name: "_method", value: @method unless @method == "POST"
        error_summary unless @errors.empty?
@@FORM_FIELDS@@
        div class: "actions" do
          # frappe:only locales
          button(class: "button", type: "submit") { t.@@PLURAL@@.save_record }
          # frappe:else
          button(class: "button", type: "submit") { "Save @@LABEL@@" }
          # frappe:end
          # frappe:only index
          # frappe:only locales
          a(class: "cancel", href: @action) { t.common.cancel }
          # frappe:else
          a(class: "cancel", href: @action) { "Cancel" }
          # frappe:end
          # frappe:else
          # frappe:only tenant
          back = @method == "POST" ? tenant_path("/") : @action
          # frappe:else
          back = @method == "POST" ? "/" : @action
          # frappe:end
          # frappe:only locales
          a(class: "cancel", href: back) { t.common.cancel }
          # frappe:else
          a(class: "cancel", href: back) { "Cancel" }
          # frappe:end
          # frappe:end
        end
      end
    end

    private def error_summary : Nil
      div class: "errors", role: "alert", tabindex: "-1", id: "form-errors" do
        # frappe:only locales
        p { t.common.check_fields }
        # frappe:else
        p { "Please check the fields below." }
        # frappe:end
        ul do
          @errors.each do |field, messages|
            # frappe:only locales
            messages.each { |message| li { field == "_base" ? message : "#{field_label(field)}: #{message}" } }
            # frappe:else
            messages.each { |message| li { field == "_base" ? message : "#{field}: #{message}" } }
            # frappe:end
          end
        end
      end
    end

    # frappe:only locales
    private def field_label(name : String) : String
      labels = {
@@FIELD_LABELS@@
      }
      labels[name]? || name
    end

    # frappe:end
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
