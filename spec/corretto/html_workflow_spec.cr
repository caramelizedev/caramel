require "spec"
require "../../src/caramel/corretto"
require "../fixtures/corretto/html_workflow_app"

describe "Corretto HTML authoring workflows" do
  it "describes a real form with captured routes, labels, CSRF and htmx attributes" do
    client = HTMLWorkflow.client
    title = %(O'Reilly & <partners> "VIP")
    shown = client.get("/orders/new", params: {"title" => title})
    token = client.cookies[Caramel::CSRF::COOKIE_NAME]
    form_path = "/orders"

    shown.should render_page("New order")
    shown.should have_html {
      section(class: "checkout") {
        h1 { "New order" }
        form(action: form_path, method: "post", hx_post: form_path, hx_target: "#order-form") {
          input(type: "hidden", name: "_csrf", value: token)
          label(for: "title") { "Order title" }
          input(id: "title", name: "title", value: title, required: true, aria_required: "true")
          input(type: "number", name: "copies", value: 1, min: 1, required: true)
          button(type: "submit", disabled: false) { "Place order" }
        }
        a(href: "/help?topic=orders&from=checkout") { "Order help" }
      }
    }
  end

  it "uses presence for native booleans and literal false strings for ARIA and data" do
    shown = HTMLWorkflow.client.get("/orders/new")
    shown.should have_html {
      form(id: "order-form") {
        fieldset(disabled: false) {
          input(type: "checkbox", checked: false)
        }
        button(aria_expanded: "false", data: {busy: "false", order_count: 0}) {
          "More options"
        }
      }
    }
    shown.should_not have_html { input(type: "checkbox", checked: true) }
    shown.should_not have_html { button(aria_expanded: "true") }
    shown.should_not have_html { button(aria_expanded: false) { "More options" } }
  end

  it "describes selected dropdown values with ordinary Crystal loops" do
    choices = [{"collection", "Collect in store", true}, {"post", "Post to me", false}]
    shown = HTMLWorkflow.client.get("/orders/new")
    shown.should have_html {
      select_tag(name: "delivery") {
        choices.each do |value, caption, selected|
          option(value: value, selected: selected) { caption }
        end
      }
    }
    shown.should have_html(within: "select[name=delivery]", count: 1) { option(selected: true) }
  end

  it "finds a real contract error and then accepts a corrected request" do
    client = HTMLWorkflow.client
    rejected = client.post("/orders", params: {"title" => "Tea", "copies" => 0})
    rejected.should have_status(422)
    rejected.should have_html {
      section(role: "alert", class: "validation") {
        h1 { "Check your order" }
        li {
          code { "copies" }
          plain ": must be at least 1"
        }
      }
    }

    accepted = client.post("/orders", params: {"title" => "Tea", "copies" => 2})
    accepted.should have_status(201)
    accepted.should_not have_html { section(role: "alert") }
    accepted.should render_partial("#orders", swap: "beforeend") { li { strong { "Tea" } } }
  end

  it "checks decoded user content in the correct region of a multi-target response" do
    title = "<b>Tea & biscuits</b> &amp; café"
    created = HTMLWorkflow.client.post(
      "/orders",
      headers: {"HX-Request" => "true"},
      params: {"title" => title, "copies" => 2},
    )
    created.should render_partial("#orders", swap: "beforeend") {
      li(class: "order", data: {order_id: 9}) {
        strong { title }
        plain " ×"
        small { 2 }
        a(href: "/orders/9/edit", title: title) { "Edit" }
      }
    }
    created.should render_partial("#order-status", swap: "innerMorph") {
      p(role: "status", aria_live: "polite") { "Added #{title}" }
    }
    created.should_not render_partial("#orders") { p(role: "status") }
    created.should_not render_partial("#order-status") { li(class: "order") }
    created.should_not have_html { b { "Tea & biscuits" } }
  end

  it "asserts repeated records by selected facts without rebuilding an expected view" do
    orders = [{7, "Tea & biscuits", 2}, {8, "Café <special>", 1}]
    shown = HTMLWorkflow.client.get("/orders")
    shown.should have_html {
      ul(id: "orders") {
        orders.each do |id, title, copies|
          li(data: {order_id: id}) {
            strong { title }
            small { copies }
            a(href: "/orders/#{id}/edit") { "Edit" }
          }
        end
      }
    }
    shown.should have_html(within: "#orders", count: 2) { li(class: "order") }
    shown.should have_html(within: "#orders", count: 1) { li { strong { "Café <special>" } } }
  end

  it "explains a failed nested requirement and permits correcting the same assertion" do
    shown = HTMLWorkflow.client.get("/orders")
    failure = expect_raises(Spec::AssertionFailed) do
      shown.should have_html {
        ul(id: "orders") { li(data: {order_id: 7}) { small { "3" } } }
      }
    end
    message = failure.message.not_nil!
    message.should contain("ul[id=\"orders\"] > li[data-order-id=\"7\"] > small")
    message.should contain(%(expected text "3", got "2"))
    message.should contain("; found 0")
    message.should contain("Tea &amp; biscuits")

    shown.should have_html {
      ul(id: "orders") { li(data: {order_id: 7}) { small { "2" } } }
    }
  end
end
