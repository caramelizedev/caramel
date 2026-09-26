require "spec"
require "../../src/caramel"

describe Caramel::Hypermedia do
  it "renders escaped hx-partial targets with an allowlisted swap" do
    html = Caramel::Hypermedia.render([
      Caramel::Partial.new("#a", "<p>A</p>"),
      Caramel::Partial.new(%(#b"><script>), "<b>B</b>", "innerHTML"),
    ])
    html.should eq(%(<hx-partial hx-target="#a" hx-swap="innerMorph"><p>A</p></hx-partial>) +
                   %(<hx-partial hx-target="#b&quot;&gt;&lt;script&gt;" hx-swap="innerHTML"><b>B</b></hx-partial>))
  end

  it "refuses unknown swaps and empty or oversized targets" do
    expect_raises(ArgumentError) { Caramel::Hypermedia.render([Caramel::Partial.new("#a", "", "innerHTML\" onload=\"x")]) }
    expect_raises(ArgumentError) { Caramel::Hypermedia.render([Caramel::Partial.new("", "")]) }
    expect_raises(ArgumentError) { Caramel::Hypermedia.render([Caramel::Partial.new("#" + "a" * 256, "")]) }
  end
end

describe Caramel::Island do
  it "escapes props into a morph-safe custom element" do
    tag = Caramel::Island.tag("Counter", {label: %(<b>"hi"</b>), n: 1}).to_s
    tag.should eq(%(<caramel-island component="Counter" props="{&quot;label&quot;:&quot;&lt;b&gt;\\&quot;hi\\&quot;&lt;/b&gt;&quot;,&quot;n&quot;:1}" hx-morph-skip-children></caramel-island>))
  end

  it "requires PascalCase component names" do
    ["lowercase", "Bad-Name", "", "A" * 65].each do |name|
      expect_raises(ArgumentError) { Caramel::Island.tag(name, {} of String => String) }
    end
  end
end
