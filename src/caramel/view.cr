# SPDX-License-Identifier: Apache-2.0
require "./html"

module Caramel
  # Compile-time ECR rendering with HTML escaping for every interpolation.
  module View
    CompilerPath = "#{__DIR__}/view/compiler"

    # Embeds an ECR template and returns its rendered String.
    #
    # Expressions resolve in the caller's lexical scope, so Crystal reports
    # an unknown template local as a normal compile-time error. Values marked
    # with HTML::Safe pass through the escape helper unchanged.
    # The hygienic buffer forwarding follows the Crystal 1.21 stdlib ECR
    # embed/render macro convention in src/ecr/macros.cr (Apache-2.0; see
    # THIRD_PARTY_NOTICES.md).
    macro render(filename)
      ::String.build do |%io|
        ::Caramel::View.embed({{filename}}, %io)
      end
    end

    macro embed(filename, io_name)
      \{{ run({{CompilerPath}}, {{filename}}, {{io_name.id.stringify}}) }}
    end
  end

  # Conventional template lookup for application actions: `view "books/show"`
  # renders <project>/app/views/books/show.html.ecr from any file under
  # <project>/app/actions. Named arguments become template locals; the macro's
  # own parameters are prefixed so any local name, including `name`, is free.
  module Templates
    macro view(__caramel_template, __caramel_dir = __DIR__, **locals)
      {% root = __caramel_dir.gsub(/\/app\/actions(\/.*)?\z/, "") %}
      {% if root == __caramel_dir %}
        {% __caramel_template.raise "view must be called from a file under app/actions (called from #{__caramel_dir.id})" %}
      {% end %}
      ({% for key, value in locals %}{{key.id}} = {{value}}; {% end %}::Caramel::View.render({{"#{root.id}/app/views/#{__caramel_template.id}.html.ecr"}}))
    end
  end
end
