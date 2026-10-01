require "spec"
require "../../src/caramel/corretto"

describe "Corretto's pinned native template binding" do
  it "matches the actual C dependency's sizes, offsets and node types" do
    definitions = {
      "NODE_SIZE"         => sizeof(Corretto::HTML::TemplateNative::Node),
      "NAMESPACE_OFFSET"  => offsetof(Corretto::HTML::TemplateNative::Node, @namespace),
      "ELEMENT_SIZE"      => sizeof(Corretto::HTML::TemplateNative::Element),
      "TEMPLATE_SIZE"     => sizeof(Corretto::HTML::TemplateNative::Template),
      "CONTENT_OFFSET"    => offsetof(Corretto::HTML::TemplateNative::Template, @content),
      "HTML_NAMESPACE"    => Lexbor::Lib::NsIdT::LXB_NS_HTML.value,
      "DOCUMENT_FRAGMENT" => Corretto::HTML::TemplateNative::DOCUMENT_FRAGMENT,
    }
    fixture = File.expand_path("../fixtures/corretto/html_template_layout.c", __DIR__)
    arguments = ["-std=c11", "-fsyntax-only", fixture]
    arguments.concat(definitions.map { |name, value| "-DCORRETTO_#{name}=#{value}" })
    diagnostics = IO::Memory.new
    status = Process.run(ENV["CC"]? || "cc", arguments, error: diagnostics)
    status.success?.should be_true, diagnostics.to_s
  end
end
