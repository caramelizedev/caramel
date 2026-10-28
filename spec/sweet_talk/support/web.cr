# Actions that call the tea shop and the shelf, to show how an action answers
# SweetTalk's errors (ADR 0034).
module TeaShopWeb
  abstract struct PageAction < Caramel::Action
    def layout(page : Caramel::Page) : String
      title = Caramel::HTML.escape(title_for(page))
      "<!DOCTYPE html><html><head><title>#{title}</title></head><body>#{page.body}</body></html>"
    end
  end

  struct Hold < PageAction
    contract do
      field tea : Int64
      field tins : Int32
    end

    def handle(contract : Contract) : Caramel::Response
      tea = TeaShop::Catalogue::Tea.find(TeaShop::Catalogue::Tea::Id.new(contract.tea))
      tea.hold(TeaShop::Catalogue::Tins.new(contract.tins))
      Caramel::Response.new(200, "held")
    end
  end

  # Re-renders its form, with the refusal, as it would on a failed contract.
  struct HoldForm < PageAction
    contract do
      field tea : Int64
      field tins : Int32
    end

    def handle(contract : Contract) : Caramel::Response
      tea = TeaShop::Catalogue::Tea.find(TeaShop::Catalogue::Tea::Id.new(contract.tea))
      tea.hold(TeaShop::Catalogue::Tins.new(contract.tins))
      Caramel::Response.new(200, "held")
    end

    def contract_failure_page(contract : Caramel::RequestContract) : Caramel::Response
      page("Hold tins", "<form>#{contract.errors["_base"]?}</form>", 422)
    end
  end

  # Rescues the refusal itself.
  struct HoldOrConflict < PageAction
    contract do
      field tea : Int64
      field tins : Int32
    end

    def handle(contract : Contract) : Caramel::Response
      tea = TeaShop::Catalogue::Tea.find(TeaShop::Catalogue::Tea::Id.new(contract.tea))
      tea.hold(TeaShop::Catalogue::Tins.new(contract.tins))
      Caramel::Response.new(200, "held")
    rescue error : SweetTalk::Refusal
      Caramel::Response.new(409, error.message.to_s)
    end
  end

  # Changes a second box inside the first box's command.
  struct FillWith < PageAction
    contract do
      field box : Int64
      field from : Int64
    end

    def handle(contract : Contract) : Caramel::Response
      box = Rules::Shelf::Box.find(Rules::Shelf::Box::Id.new(contract.box))
      box.fill_with(Rules::Shelf::Box.find(Rules::Shelf::Box::Id.new(contract.from)))
      Caramel::Response.new(200, "filled")
    end
  end

  # Binds an aggregate's id, values and a list of values as contract fields; ids here
  # need no row.
  struct AddLine < PageAction
    ingress csrf: false, authenticate: :allowed?

    contract do
      field order : TeaShop::Ordering::Order::Id
      field quantity : TeaShop::Ordering::Quantity
      field receipt_to : TeaShop::Ordering::Email?
      field tags : Array(TeaShop::Ordering::Quantity), max: 3
    end

    def handle(contract : Contract) : Caramel::Response
      Caramel::Response.new(200, "order=#{contract.order.raw} quantity=#{contract.quantity.raw}")
    end

    private def allowed? : Bool
      true
    end
  end

  # Binds calendar days, one required, one optional and a list, from YYYY-MM-DD, and answers
  # them as JSON.
  struct Lend < PageAction
    ingress csrf: false, authenticate: :allowed?

    contract do
      field lent_on : Library::Lending::Day
      field back_by : Library::Lending::Day?
      field holidays : Array(Library::Lending::Day), max: 3
    end

    def handle(contract : Contract) : Caramel::Response
      between = contract.back_by.try { |day| day - contract.lent_on }
      json({lent_on: contract.lent_on, back_by: contract.back_by, holidays: contract.holidays,
            days: between})
    end

    private def allowed? : Bool
      true
    end
  end

  # Binds a decimal value, required and optional, from its text, and answers it as JSON.
  struct Price < PageAction
    ingress csrf: false, authenticate: :allowed?

    contract do
      field rate : Treasury::Credit::Rate
      field spread : Treasury::Credit::Spread?
    end

    def handle(contract : Contract) : Caramel::Response
      json({rate: contract.rate, spread: contract.spread})
    end

    private def allowed? : Bool
      true
    end
  end

  Caramel::Router.draw do
    get "/teas/:tea/hold", Hold
    get "/teas/:tea/form", HoldForm
    get "/teas/:tea/claim", HoldOrConflict
    get "/boxes/:box/fill", FillWith
    post "/orders/:order/lines", AddLine
    post "/loans/lend", Lend
    post "/loans/price", Price
  end
end
