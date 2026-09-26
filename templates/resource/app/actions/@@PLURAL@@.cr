module App::@@COLLECTION@@
  # Shared by the actions that render the @@LABEL@@ form.
  module Form
    private def render_form(values : Hash(String, String), errors : Hash(String, Array(String)), id : Int64? = nil, status : Int32 = 200) : Caramel::Response
      action = id ? @@SINGULAR@@_path(id) : @@PLURAL@@_path
      method = id ? "PATCH" : "POST"
      form = Caramel::HTML::Safe.new(Caramel::View.render "#{__DIR__}/../views/@@PLURAL@@/_form.html.ecr")
      content = if id
                  Caramel::View.render "#{__DIR__}/../views/@@PLURAL@@/edit.html.ecr"
                else
                  Caramel::View.render "#{__DIR__}/../views/@@PLURAL@@/new.html.ecr"
                end
      page(Caramel::Page.new(id ? "Edit @@LABEL@@" : "New @@LABEL@@", content), status)
    end

    # Re-renders the submitted form with every contract error.
    def contract_failure_page(contract : Caramel::RequestContract) : Caramel::Response
      render_form(contract.values, contract.errors, contract.values["id"]?.try(&.to_i64?), 422)
    end
  end
end
