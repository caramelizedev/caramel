require "../spec_helper"

describe "Home" do
  it "renders a full page and a fragment with the same locally served assets" do
    Corretto.session do |client|
      page = client.get("/")
      page.should have_status(200)
      page.should render_page("@@TITLE@@")
      page.should have_html { script(src: "/assets/htmx-4.0.0.min.js") }
      fragment = client.get("/", headers: {"HX-Request" => "true", "HX-Request-Type" => "partial"})
      fragment.should have_status(200)
      fragment.should_not render_page("@@TITLE@@")
      fragment.should have_html { title { "Welcome · @@TITLE@@" } }
    end
  end
end
