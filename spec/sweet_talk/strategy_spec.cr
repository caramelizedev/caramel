require "./support/app"

# The tea house's strategic design (ADR 0036).
describe "SweetTalk strategic design" do
  it "marks each context's subdomain in the glossary" do
    names = %w[Billing Catalogue Insurance Pricing]
    marked = SweetTalk.glossary
      .select { |term| term.kind == "context" && names.includes?(term.name) }
      .map { |term| {term.name, term.subdomain} }
    marked.sort_by(&.[0]).should eq([
      {"Billing", "core"}, {"Catalogue", nil}, {"Insurance", "generic"}, {"Pricing", "supporting"},
    ])
  end

  it "gives every term its context's subdomain, and keeps the four-argument Term" do
    reference = SweetTalk.glossary.find do |term|
      term.kind == "value" && term.name == "Reference" && term.context == "Billing"
    end
    reference.try(&.subdomain).should eq("core")
    term = SweetTalk::Term.new("context", "Ordering", "Ordering", "choosing teas and checking out")
    term.subdomain.should be_nil
  end
end
