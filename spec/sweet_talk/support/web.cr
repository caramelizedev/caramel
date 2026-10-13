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

  Caramel::Router.draw do
    get "/teas/:tea/hold", Hold
    get "/teas/:tea/form", HoldForm
    get "/teas/:tea/claim", HoldOrConflict
    get "/boxes/:box/fill", FillWith
  end
end
