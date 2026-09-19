module App
  class @@CONTROLLER@@ < ApplicationController
    def index : Caramel::Response
      records = @@MODEL@@.order(id: :desc).limit(100).to_a
      content = Caramel::View.render "#{__DIR__}/../views/@@PLURAL@@/index.html.ecr"
      page(content, "@@COLLECTION_LABEL@@")
    end

    def show(id : Int64) : Caramel::Response
      record = @@MODEL@@.find(id)
      return missing unless record
      content = Caramel::View.render "#{__DIR__}/../views/@@PLURAL@@/show.html.ecr"
      page(content, "@@MODEL@@")
    end

    def new : Caramel::Response
      render_form({} of String => String, {} of String => Array(String))
    end

    def edit(id : Int64) : Caramel::Response
      record = @@MODEL@@.find(id)
      return missing unless record
      values = {@@VALUES@@}
      render_form(values, {} of String => Array(String), id)
    end

    def create : Caramel::Response
      persist(parse_form(@@MODEL@@Input))
    end

    def update(id : Int64) : Caramel::Response
      persist(parse_form(@@MODEL@@Input), id)
    end

    def destroy(id : Int64) : Caramel::Response
      form = parse_form("@@SINGULAR@@", [] of String)
      return Caramel::Response.new(422, "Invalid delete form") unless form.valid?
      remove(id)
    end

    # Native browser forms submit POST; CSRF and the bounded form parser run
    # before honoring a method override. PATCH/DELETE also have direct routes.
    def change(id : Int64) : Caramel::Response
      form = parse_form(@@MODEL@@Input.envelope, @@MODEL@@Input.fields, required_fields: [] of String)
      return render_form(form.values, form.field_errors, id, 422) unless form.valid?
      case form.method(request.method)
      when "PATCH", "PUT"
        persist(@@MODEL@@Input.from_form(form), id)
      when "DELETE"
        return Caramel::Response.new(422, "Invalid delete form") unless form.values.empty?
        remove(id)
      else
        Caramel::Response.new(405, "Use the edit or delete form")
      end
    end

    private def persist(result : Caramel::FormInput::Result(@@MODEL@@Input), id : Int64? = nil) : Caramel::Response
      existing = id ? @@MODEL@@.find(id) : nil
      return missing if id && !existing
      input = result.value
      return render_form(result.values, result.errors, id, 422) unless input && result.valid?
      record = if existing
@@ASSIGNMENTS@@
        existing
      else
        @@MODEL@@.new(@@ATTRIBUTES@@)
      end
      if record.save
        redirect_to(@@SINGULAR@@_path(record.id.not_nil!))
      else
        render_form(result.values, record.errors, id, 422)
      end
    end

    private def remove(id : Int64) : Caramel::Response
      record = @@MODEL@@.find(id)
      return missing unless record && record.delete
      redirect_to(@@PLURAL@@_path)
    end

    private def missing : Caramel::Response
      Caramel::Response.new(404, "@@MODEL@@ not found")
    end

    private def render_form(values : Hash(String, String), errors : Hash(String, Array(String)), id : Int64? = nil, status : Int32 = 200) : Caramel::Response
      action = id ? @@SINGULAR@@_path(id) : @@PLURAL@@_path
      method = id ? "PATCH" : "POST"
      form = Caramel::HTML::Safe.new(Caramel::View.render "#{__DIR__}/../views/@@PLURAL@@/_form.html.ecr")
      content = if id
        Caramel::View.render "#{__DIR__}/../views/@@PLURAL@@/edit.html.ecr"
      else
        Caramel::View.render "#{__DIR__}/../views/@@PLURAL@@/new.html.ecr"
      end
      page(content, id ? "Edit @@LABEL@@" : "New @@LABEL@@", status)
    end
  end
end
