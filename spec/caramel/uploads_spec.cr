require "spec"
require "../../src/caramel"

abstract struct UploadsSpecAction < Caramel::Action
  def layout(page : Caramel::Page) : String
    page.body
  end
end

# A form with no file field.
struct UploadsSpecCreateBook < UploadsSpecAction
  contract do
    field title : String
  end

  def handle(contract : Contract)
    Caramel::Response.new(201, contract.title)
  end
end

struct UploadsSpecCreateCover < UploadsSpecAction
  contract do
    field cover : Caramel::UploadedFile
  end

  def handle(contract : Contract)
    Caramel::Response.new(201, File.read(contract.cover.path))
  end
end

# Reached only through a POST form's `_method`.
struct UploadsSpecReplaceCover < UploadsSpecAction
  contract do
    field id : Int64
    field cover : Caramel::UploadedFile
  end

  def handle(contract : Contract)
    Caramel::Response.new(200, File.read(contract.cover.path))
  end
end

module UploadsSpecApp
  Caramel::Router.draw do
    post "/books", UploadsSpecCreateBook
    post "/covers", UploadsSpecCreateCover
    patch "/covers/:id", UploadsSpecReplaceCover
  end
end

private UPLOADS_CSRF = Caramel::CSRF.new("s" * 64, "https://bookshelf.caramel")
private UPLOADS_APP  = Caramel::Application.new(UploadsSpecApp::AppRouter.new, UPLOADS_CSRF)

# A same-origin browser's multipart POST with a file part named *name*, then a
# text part of the same name when *text_after* is set.
private def upload(path : String,
                   name : String,
                   override : String? = nil,
                   text_after : String? = nil) : Caramel::Response
  token = UPLOADS_CSRF.issue
  io = IO::Memory.new
  form = HTTP::FormData::Builder.new(io, "caramel-boundary")
  form.field("_csrf", token)
  override.try { |method| form.field("_method", method) }
  form.field("title", "Dune") if path == "/books"
  metadata = HTTP::FormData::FileMetadata.new(filename: "cover.png")
  form.file(name, IO::Memory.new("image bytes"), metadata)
  text_after.try { |text| form.field(name, text) }
  form.finish
  headers = HTTP::Headers{
    "Host"         => "bookshelf.caramel",
    "Content-Type" => form.content_type,
    "Origin"       => "https://bookshelf.caramel",
    "Cookie"       => "#{Caramel::CSRF::COOKIE_NAME}=#{token}",
  }
  UPLOADS_APP.handle(HTTP::Request.new("POST", path, headers, io.to_s))
end

private def stored_uploads : Int32
  Dir.glob(File.join(Dir.tempdir, "caramel-upload-*")).size
end

describe "Caramel uploads" do
  it "marks only the routes whose contract takes a file" do
    routes = UploadsSpecApp::AppRouter.routes
    routes.map(&.uploads).should eq([false, true, true])
  end

  it "stores a file for a route whose contract takes one and deletes it afterwards" do
    before = stored_uploads
    created = upload("/covers", "cover")
    {created.status, created.body}.should eq({201, "image bytes"})
    stored_uploads.should eq(before)
  end

  it "stores a file for a route that a POST form's _method reaches" do
    replaced = upload("/covers/5", "cover", override: "PATCH")
    {replaced.status, replaced.body}.should eq({200, "image bytes"})
  end

  it "answers 422 for a file sent to a route that takes none" do
    refused = upload("/books", "cover")
    refused.status.should eq(422)
    refused.body.should contain("Unknown field: cover")
  end

  it "answers 422 for a text part that repeats a refused file part's name" do
    refused = upload("/books", "cover", text_after: "again")
    refused.status.should eq(422)
  end

  it "reads no file for a path that matches no route" do
    upload("/nowhere", "cover").status.should eq(404)
  end
end
