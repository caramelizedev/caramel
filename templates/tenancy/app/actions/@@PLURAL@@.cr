module App::@@COLLECTION@@
  # Shared by the actions that render the @@LABEL@@ sign-up form.
  module Form
    private def render_form(values : Hash(String, String),
                            errors : Hash(String, Array(String)),
                            status : Int32 = 200) : Caramel::Response
      form = Views::@@COLLECTION@@::Form.new(@@PLURAL@@_path, csrf_token, values, errors)
      page "New @@LABEL@@", Views::@@COLLECTION@@::New.new(form), status
    end

    # Re-renders the submitted form with every contract error.
    def contract_failure_page(contract : Caramel::RequestContract) : Caramel::Response
      render_form(contract.values, contract.errors, 422)
    end
  end
end
