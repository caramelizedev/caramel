module App::@@COLLECTION@@
  # Shared by the actions that render the @@LABEL@@ form.
  module Form
    private def render_form(values : Hash(String, String), errors : Hash(String, Array(String)), id : @@ID@@? = nil, status : Int32 = 200) : Caramel::Response
      action = id ? @@SINGULAR@@_path(id) : @@PLURAL@@_path
      form = Views::@@COLLECTION@@::Form.new(action, id ? "PATCH" : "POST", csrf_token, values, errors)
      # frappe:only edit
      if id
        # frappe:only locales
        page t.@@PLURAL@@.edit_record, Views::@@COLLECTION@@::Edit.new(id, form), status
        # frappe:else
        page "Edit @@LABEL@@", Views::@@COLLECTION@@::Edit.new(id, form), status
        # frappe:end
      else
        # frappe:only locales
        page t.@@PLURAL@@.new_record, Views::@@COLLECTION@@::New.new(form), status
        # frappe:else
        page "New @@LABEL@@", Views::@@COLLECTION@@::New.new(form), status
        # frappe:end
      end
      # frappe:else
      # frappe:only locales
      page t.@@PLURAL@@.new_record, Views::@@COLLECTION@@::New.new(form), status
      # frappe:else
      page "New @@LABEL@@", Views::@@COLLECTION@@::New.new(form), status
      # frappe:end
      # frappe:end
    end

    # Re-renders the submitted form with every contract error.
    def contract_failure_page(contract : Caramel::RequestContract) : Caramel::Response
      id = contract.values["id"]?.try { |text| Caramel::RequestContract.convert(text, @@ID@@) }
      render_form(contract.values, contract.errors, id, 422)
    end
  end
end
