# A sale previewed on GET and committed on POST against the fingerprint the form carried
# in a hidden field (ADR 0060).
module PreviewWeb
  # The form that confirms a sale: what it would record, and the fingerprint to commit.
  def self.form(preview : SweetTalk::Preview, status : Int32 = 200) : Caramel::Response
    lines = preview.summary.map { |group| "#{group.aggregate} #{group.what}" }.join("; ")
    body = %(<form method="post"><p>#{lines}</p>) +
           %(<input type="hidden" name="expected" value="#{preview.fingerprint}"></form>)
    Caramel::Response.new(status, body)
  end

  def self.sale(contract) : PreviewShop::Till::Receipt::Id
    PreviewShop::Till.sell(PreviewShop::Till::Tea::Id.new(contract.tea),
      PreviewShop::Till::Tins.new(contract.tins))
  end

  struct ShowSale < Caramel::Action
    contract do
      field tea : Int64
      field tins : Int32
    end

    def handle(contract : Contract) : Caramel::Response
      PreviewWeb.form(SweetTalk.preview { PreviewWeb.sale(contract) })
    end
  end

  # Commits the sale, or shows the form again with the fresh preview when it went stale.
  struct Sell < Caramel::Action
    ingress csrf: false, authenticate: :allowed?

    contract do
      field tea : Int64
      field tins : Int32
      field expected : SweetTalk::Fingerprint
    end

    def handle(contract : Contract) : Caramel::Response
      receipt = SweetTalk.commit(contract.expected) { PreviewWeb.sale(contract) }
      Caramel::Response.new(200, "receipt #{receipt}")
    end

    def render_stale(contract : Caramel::RequestContract,
                     stale : SweetTalk::Stale) : Caramel::Response
      return super unless @context.browser?
      PreviewWeb.form(stale.preview, 422)
    end

    private def allowed? : Bool
      true
    end
  end

  Caramel::Router.draw do
    get "/till/:tea/sell", ShowSale
    post "/till/:tea/sell", Sell
  end
end
