module App::@@COLLECTION@@
  struct Create < App::ApplicationAction
    include Form

    contract do
      field name : String
      field slug : String
    end

    def handle(contract : Contract)
      changes = App::@@MODEL@@.create(name: contract.name, slug: contract.slug)
      return render_form(contract.values, changes.errors, 422) unless changes.saved?
      join(changes.record)
      self.status = 201
      {record: changes.record}
    end

    def render(result)
      redirect_to("/#{result[:record].slug}")
    end

    # The session signed up this @@LABEL@@, so member? lets it in.
    private def join(record : App::@@MODEL@@) : Nil
      members = session["@@PLURAL@@"]?
      session["@@PLURAL@@"] = members ? "#{members},#{record.slug}" : record.slug
    end
  end
end
