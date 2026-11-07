require "spec"
require "../../src/frappe/glossary"

private def document : JSON::Any
  JSON.parse(<<-JSON)
    {
      "terms": [
        {"kind": "kernel", "name": "Money", "context": "Money", "means": "money we agree on",
         "subdomain": null, "facts": {"follows": [], "shares": [],
         "shared_by": ["Pricing", "Billing"]}},
        {"kind": "value", "name": "Cents", "context": "Money", "means": "an amount | in cents",
         "subdomain": null, "facts": {"wraps": ["Int64"], "at_least": ["0"]}},
        {"kind": "context", "name": "Billing", "context": "Billing", "means": "billing guests",
         "subdomain": "core", "facts": {"follows": ["Pricing"], "shares": ["Money"]}},
        {"kind": "event", "name": "Bill::Paid", "context": "Billing", "means": "a bill was paid",
         "subdomain": "core", "facts": {"handlers": ["Owed", "Billing, after: Owed"]}},
        {"kind": "context", "name": "Pricing", "context": "Pricing", "means": "setting prices",
         "subdomain": null, "facts": {"follows": [], "shares": ["Money"]}}
      ],
      "map": [["Billing", "Pricing", "dependency"], ["Billing", "Pricing", "event"],
              ["Pricing", "Money", "kernel"], ["Billing", "Cards", "outside"]]
    }
    JSON
end

describe Caramel::Frappe::Glossary do
  it "prints one section per context or kernel, with its terms and their facts" do
    markdown = Caramel::Frappe::Glossary.new(document).to_markdown
    markdown.should eq(<<-MARKDOWN)
      # Glossary

      ## Money (kernel)

      money we agree on

      shared_by: Pricing, Billing

      | Term | Kind | Means | Facts |
      | --- | --- | --- | --- |
      | Cents | value | an amount \\| in cents | wraps: Int64; at_least: 0 |

      ## Billing (context, core)

      billing guests

      follows: Pricing; shares: Money

      | Term | Kind | Means | Facts |
      | --- | --- | --- | --- |
      | Bill::Paid | event | a bill was paid | handlers: Owed, Billing, after: Owed |

      ## Pricing (context)

      setting prices

      shares: Money

      MARKDOWN
  end

  it "prints the context map as text, each module with the edges that leave it" do
    Caramel::Frappe::Glossary.new(document).to_text.should eq(<<-TEXT)
      Money
      Billing
        depends on Pricing
        reacts to Pricing
        calls Cards
      Pricing
        shares Money

      TEXT
  end

  it "prints the context map as a Mermaid flowchart" do
    Caramel::Frappe::Glossary.new(document).to_mermaid.should eq(<<-MERMAID)
      flowchart LR
        Money
        Billing
        Pricing
        Billing -->|depends on| Pricing
        Billing -.->|reacts to| Pricing
        Pricing ---|shares| Money
        Billing -->|calls| Cards{{Cards}}

      MERMAID
  end
end
