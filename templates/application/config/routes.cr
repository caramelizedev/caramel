module App
  Caramel::Router.draw do
    get "/", App::Home::Show
    get "/health", App::Health::Show
    # Frappé resource routes
  end
end
