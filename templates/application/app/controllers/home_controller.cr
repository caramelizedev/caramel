module App
  class HomeController < ApplicationController
    def index : Caramel::Response
      content = Caramel::View.render "#{__DIR__}/../views/home/index.html.ecr"
      page(content, "Welcome")
    end
  end
end
