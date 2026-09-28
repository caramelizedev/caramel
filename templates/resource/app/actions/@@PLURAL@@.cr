module App::@@COLLECTION@@
  # Shared by the actions that render the @@LABEL@@ form.
  module Form
    private def render_form(values : Hash(String, String), errors : Hash(String, Array(String)), id : Int64? = nil, status : Int32 = 200) : Caramel::Response
      action = id ? @@SINGULAR@@_path(id) : @@PLURAL@@_path
      form = Caramel::HTML::Safe.new(view("@@PLURAL@@/_form", action: action, method: id ? "PATCH" : "POST"))
      if id
        page "Edit @@LABEL@@", view("@@PLURAL@@/edit", form: form), status
      else
        page "New @@LABEL@@", view("@@PLURAL@@/new", form: form), status
      end
    end

    # Re-renders the submitted form with every contract error.
    def contract_failure_page(contract : Caramel::RequestContract) : Caramel::Response
      render_form(contract.values, contract.errors, contract.values["id"]?.try(&.to_i64?), 422)
    end
  end
end
