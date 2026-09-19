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
end
