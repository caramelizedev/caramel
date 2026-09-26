module App::@@COLLECTION@@
  class Create < App::ApplicationAction
    include Form

    contract do
@@CONTRACT_FIELDS@@
    end

    struct Result
      include JSON::Serializable
      getter record : App::@@MODEL@@

      def initialize(@record)
      end
    end

    def handle(contract : Contract) : Result | Caramel::Response
      record = App::@@MODEL@@.new(@@ATTRIBUTES@@)
      return render_form(contract.values, record.errors, nil, 422) unless record.save
      self.status = 201
      Result.new(record)
    end

    def respond_html(result : Result) : Caramel::Response
      redirect_to(@@SINGULAR@@_path(result.record.id.not_nil!))
    end
  end
end
