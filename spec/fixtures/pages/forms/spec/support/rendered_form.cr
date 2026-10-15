# Submits the first form on *page* as a browser would: every named input,
# select and textarea it renders, with *fill* replacing the values it names.
def submit_rendered_form(client : Corretto::Client, page : Caramel::Response,
                         fill : Hash(String, String)) : Caramel::Response
  action, verb, values = read_form(page.body)
  fill.each do |name, value|
    raise ArgumentError.new("The form has no field #{name}") unless values.has_key?(name)
    values[name] = value
  end
  verb == "post" ? client.post(action, params: values) : client.get(action, params: values)
end

# The form's action, its method and the value of each field it renders.
private def read_form(html : String) : {String, String, Hash(String, String)}
  Corretto::HTML::Document.open(html) do |document|
    form = document.select("form").first? || raise ArgumentError.new("The page has no form")
    action = form["action"]? || raise ArgumentError.new("The form has no action")
    values = {} of String => String
    read_inputs(form, values)
    read_selects(form, values)
    form.css("textarea[name]") { |area| values[area["name"]] = area.inner_text }
    {action, form["method"]?.try(&.downcase) || "get", values}
  end
end

# Each input that a browser submits: not a button, and not an unchecked box.
private def read_inputs(form : Lexbor::Node, values : Hash(String, String)) : Nil
  form.css("input[name]") do |input|
    type = input["type"]?.try(&.downcase) || "text"
    next if type.in?("submit", "button", "reset", "image")
    next if type.in?("checkbox", "radio") && !input.has_key?("checked")
    values[input["name"]] = input["value"]? || ""
  end
end

# Each select's selected option, or its first.
private def read_selects(form : Lexbor::Node, values : Hash(String, String)) : Nil
  form.css("select[name]") do |field|
    options = [] of {String, Bool}
    field.css("option") do |option|
      options << {option["value"]? || option.inner_text, option.has_key?("selected")}
    end
    chosen = options.find(&.[1]) || options.first?
    values[field["name"]] = chosen.try(&.[0]) || ""
  end
end
