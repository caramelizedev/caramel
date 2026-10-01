module HTMLWorkflow
  record Order, id : Int64, title : String, copies : Int32

  class Form < Caramel::View
    def initialize(@title : String, @token : String)
    end

    private def blueprint
      section(class: "checkout card") {
        h1 { "New order" }
        form(
          id: "order-form",
          method: "post",
          action: "/orders",
          hx_post: "/orders",
          hx_target: "#order-form",
          hx_swap: "innerMorph",
        ) {
          input(type: "hidden", name: "_csrf", value: @token)
          label(for: "title") { "Order title" }
          input(
            id: "title",
            name: "title",
            value: @title,
            required: true,
            aria_required: "true",
          )
          input(type: "number", name: "copies", value: 1, min: 1, required: true)
          fieldset(disabled: false) {
            legend { "Delivery" }
            select_tag(name: "delivery") {
              option(value: "collection", selected: true) { "Collect in store" }
              option(value: "post", selected: false) { "Post to me" }
            }
            input(type: "checkbox", name: "gift", checked: false)
          }
          button(
            type: "button",
            aria_expanded: "false",
            data: {busy: "false", order_count: 0},
          ) { "More options" }
          button(type: "submit", disabled: false) { "Place order" }
        }
        a(href: "/help?topic=orders&from=checkout") { "Order help" }
      }
    end
  end

  class Item < Caramel::View
    def initialize(@order : Order)
    end

    private def blueprint
      li(class: ["order", "ready"], data: {order_id: @order.id}) {
        strong { @order.title }
        plain " ×"
        small { @order.copies }
        a(href: "/orders/#{@order.id}/edit", title: @order.title) { "Edit" }
      }
    end
  end

  class List < Caramel::View
    def initialize(@orders : Array(Order))
    end

    private def blueprint
      section {
        h1 { "Orders" }
        ul(id: "orders") {
          @orders.each { |order| render Item.new(order) }
        }
      }
    end
  end

  class Errors < Caramel::View
    def initialize(@errors : Hash(String, Array(String)))
    end

    private def blueprint
      section(id: "order-errors", class: "validation card", role: "alert") {
        h1 { "Check your order" }
        ul {
          @errors.each do |field, messages|
            messages.each do |message|
              li {
                code { field }
                plain ": #{message}"
              }
            end
          end
        }
      }
    end
  end

  class Status < Caramel::View
    def initialize(@title : String)
    end

    private def blueprint
      p(role: "status", aria_live: "polite") { "Added #{@title}" }
    end
  end

  struct New < Caramel::Action
    contract do
      field title : String, default: "Guest order"
    end

    def handle(contract : Contract)
      page "New order", Form.new(contract.title, csrf_token)
    end
  end

  struct Index < Caramel::Action
    contract do
    end

    def handle(contract : Contract)
      orders = [Order.new(7, "Tea & biscuits", 2), Order.new(8, "Café <special>", 1)]
      page "Orders", List.new(orders)
    end
  end

  struct Create < Caramel::Action
    contract do
      field title : String
      field copies : Int32, min: 1
      field delivery : String, default: "collection"
      field gift : Bool, default: false
    end

    def handle(contract : Contract)
      order = Order.new(9, contract.title, contract.copies)
      item = Caramel::Partial.new("#orders", Item.new(order).to_s, "beforeend")
      status = Caramel::Partial.new("#order-status", Status.new(order.title).to_s)
      partials([item, status], 201)
    end

    def contract_failure_page(contract : Caramel::RequestContract) : Caramel::Response
      page "Check your order", Errors.new(contract.errors), 422
    end
  end

  Caramel::Router.draw do
    get "/orders/new", New
    get "/orders", Index
    post "/orders", Create
  end

  def self.client : Corretto::Client
    csrf = Caramel::CSRF.new("s" * 64, "https://shop.caramel")
    application = Caramel::Application.new(AppRouter.new, csrf)
    Corretto::Client.new(application)
  end
end
