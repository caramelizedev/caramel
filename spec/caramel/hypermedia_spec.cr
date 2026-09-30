require "spec"
require "../../src/caramel"

describe Caramel::Hypermedia do
  it "renders escaped hx-partial targets with an allowlisted swap" do
    html = Caramel::Hypermedia.render([
      Caramel::Partial.new("#a", "<p>A</p>"),
      Caramel::Partial.new(%(#b"><script>), "<b>B</b>", "innerHTML"),
    ])
    expected = %(<hx-partial hx-target="#a" hx-swap="innerMorph"><p>A</p></hx-partial>) +
               %(<hx-partial hx-target="#b&quot;&gt;&lt;script&gt;" hx-swap="innerHTML">) +
               %(<b>B</b></hx-partial>)
    html.should eq(expected)
  end

  it "refuses unknown swaps and empty or oversized targets" do
    unknown_swap = Caramel::Partial.new("#a", "", "innerHTML\" onload=\"x")
    empty = Caramel::Partial.new("", "")
    oversized = Caramel::Partial.new("#" + "a" * 256, "")
    expect_raises(ArgumentError) { Caramel::Hypermedia.render([unknown_swap]) }
    expect_raises(ArgumentError) { Caramel::Hypermedia.render([empty]) }
    expect_raises(ArgumentError) { Caramel::Hypermedia.render([oversized]) }
  end
end

describe Caramel::Island do
  it "escapes props into a morph-safe custom element" do
    tag = Caramel::Island.tag("Counter", {label: %(<b>"hi"</b>), n: 1}).to_s
    label = %(&quot;label&quot;:&quot;&lt;b&gt;\\&quot;hi\\&quot;&lt;/b&gt;&quot;)
    props = "{#{label},&quot;n&quot;:1}"
    attributes = %(component="Counter" props="#{props}" hx-morph-skip-children)
    tag.should eq("<caramel-island #{attributes}></caramel-island>")
  end

  it "requires PascalCase component names" do
    ["lowercase", "Bad-Name", "", "A" * 65].each do |name|
      expect_raises(ArgumentError) { Caramel::Island.tag(name, {} of String => String) }
    end
  end
end
