module App::Routes
  def self.build(csrf : Caramel::CSRF) : Caramel::Router
    router = Caramel::Router.new
    router.get("/") { |request, _| App::HomeController.new(request, csrf).index }
    router.get("/health") { |_, _| Caramel::Response.new(body: "ok") }
    # Frappé resource routes
    router
  end
end
