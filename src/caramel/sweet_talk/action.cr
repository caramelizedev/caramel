# How an action answers SweetTalk's errors (ADR 0034): a refusal is 422 and a missing
# aggregate 404. `SweetTalk::Boundary` is a programming error and stays a 500.
abstract struct Caramel::Action
  # :nodoc:
  def __caramel_answer(contract : Caramel::RequestContract,
                       & : -> Caramel::Response) : Caramel::Response
    yield
  rescue error : ::SweetTalk::Refusal
    render_refusal(contract, error)
  rescue ::SweetTalk::Missing
    not_found
  end

  # Answers a refusal that `handle` did not rescue with 422, the way a failed contract is
  # answered, with the refusal's message under the field it names when the contract has
  # that field, else under `_base`: JSON for JSON clients, `contract_failure_page(contract)`
  # for browsers and htmx, and MRDP text for every other client. Override it to answer a
  # refusal otherwise.
  def render_refusal(contract : Caramel::RequestContract,
                     refusal : ::SweetTalk::Refusal) : Caramel::Response
    field = refusal.on.try { |name| name if contract.field?(name) } || "_base"
    contract.add_error(field, refusal.message || "")
    return json({errors: contract.errors}, 422) if @context.wants_json?
    return contract_failure_page(contract) if @context.browser?
    Egress.text(422, Egress.errors_text(contract.errors, 422, @context.method, request.path))
  end
end
