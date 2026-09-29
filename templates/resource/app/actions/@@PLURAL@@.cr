module App::@@COLLECTION@@
  # Shared by the actions that render the @@LABEL@@ form.
  module Form
    private def render_form(values : Hash(String, String), errors : Hash(String, Array(String)), id : Int64? = nil, status : Int32 = 200) : Caramel::Response
      action = id ? @@SINGULAR@@_path(id) : @@PLURAL@@_path
      form = Views::@@COLLECTION@@::Form.new(action, id ? "PATCH" : "POST", csrf_token, values, errors)
      if id # frappe:only=edit
        page "Edit @@LABEL@@", Views::@@COLLECTION@@::Edit.new(id, form), status # frappe:only=edit
      else # frappe:only=edit
        page "New @@LABEL@@", Views::@@COLLECTION@@::New.new(form), status # frappe:only=edit
      end # frappe:only=edit
      page "New @@LABEL@@", Views::@@COLLECTION@@::New.new(form), status # frappe:unless=edit
    end

    # Re-renders the submitted form with every contract error.
    def contract_failure_page(contract : Caramel::RequestContract) : Caramel::Response
      render_form(contract.values, contract.errors, contract.values["id"]?.try(&.to_i64?), 422)
    end
  end
end
