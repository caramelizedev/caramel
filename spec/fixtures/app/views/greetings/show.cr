module Views::Greetings
  class Show < Caramel::View
    def initialize(@name : String)
    end

    private def blueprint
      p { "Hello, #{@name}" }
      render Signature.new
    end
  end

  class Signature < Caramel::View
    private def blueprint
      footer { "Caramel" }
    end
  end
end
