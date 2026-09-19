require "./application"
require "./form_input"

module Caramel
  # A controller instance belongs to one request and holds no shared request state.
  class Controller
    getter request : HTTP::Request
    getter csrf_token : String

    def initialize(@request : HTTP::Request, @csrf : CSRF)
      cookie = @request.cookies[CSRF::COOKIE_NAME]?.try(&.value)
      @csrf_token = cookie && @csrf.valid_token?(cookie) ? cookie : @csrf.issue
    end

    def parse_form(envelope : String, fields : Array(String), required_fields : Array(String) = fields) : Form
      form = Form.read(@request, envelope, fields, required_fields)
      submitted = form.csrf_token || @request.headers["X-CSRF-Token"]?
      raise Forbidden.new unless @csrf.valid?(@request, submitted)
      form
    end

    def parse_form(input_type : T.class) : FormInput::Result(T) forall T
      form = parse_form(T.envelope, T.fields, T.required_fields)
      T.from_form(form)
    end

    def change(id : Int64) : Response
      Response.new(405, "Use the edit or delete form")
    end

    def redirect_to(path : String) : Response
      Response.navigate(@request, path)
    end

    def html(full : String, partial : String, status = 200) : Response
      response = Response.html(@request, full: full, partial: partial, status: status)
      response.headers.add("Set-Cookie", @csrf.cookie(@csrf_token).to_set_cookie_header)
      response.headers["Cache-Control"] = "no-store"
      response
    end
  end
end
