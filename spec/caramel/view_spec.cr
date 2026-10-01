require "spec"
require "../../src/caramel/corretto"

private class LinkView < Caramel::View
  def initialize(@value : String)
  end

  private def blueprint
    a(href: "/items?q=#{@value}", title: @value) { @value }
  end
end

private class TrustedView < Caramel::View
  def initialize(@markup : Caramel::HTML::Safe)
  end

  private def blueprint
    div(data_markup: @markup) { raw @markup }
  end
end

private class OuterView < Caramel::View
  def initialize(@text : String)
  end

  private def blueprint
    section { render InnerView.new(@text) }
  end
end

private class InnerView < Caramel::View
  def initialize(@text : String)
  end

  private def blueprint
    span { @text }
  end
end

private class IslandView < Caramel::View
  private def blueprint
    island "Counter", {label: "first"}
  end
end

module Blueprint::HTML::AttributesRenderer
  def self.cached_attribute_sets : Int32
    CACHE.size
  end
end

describe Caramel::View do
  it "escapes attribute values like text, so a stored entity survives a round trip" do
    escaped = "Tom &amp;amp; &quot;Jerry&quot; &lt;3 &#39;"
    link = LinkView.new(%(Tom &amp; "Jerry" <3 ')).to_s
    link.should eq(%(<a href="/items?q=#{escaped}" title="#{escaped}">#{escaped}</a>))
  end

  it "writes Caramel::HTML::Safe values as they are, in text and in attributes" do
    trusted = TrustedView.new(Caramel::HTML::Safe.new("<em>trusted</em>")).to_s
    trusted.should eq(%(<div data-markup="<em>trusted</em>"><em>trusted</em></div>))
  end

  it "renders nested views into the same document, each escaping its own input" do
    OuterView.new("<inner>").to_s.should have_html { section { span { "<inner>" } } }
  end

  it "writes an island tag in place, without escaping it again" do
    props = "{&quot;label&quot;:&quot;first&quot;}"
    attributes = %(component="Counter" props="#{props}" hx-morph-skip-children)
    IslandView.new.to_s.should eq("<caramel-island #{attributes}></caramel-island>")
  end

  it "keeps no rendered attribute values after rendering" do
    LinkView.new("kept?").to_s
    Blueprint::HTML::AttributesRenderer.cached_attribute_sets.should eq(0)
  end
end
