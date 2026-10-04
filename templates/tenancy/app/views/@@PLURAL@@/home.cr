module App::Views::@@COLLECTION@@
  class Home < App::ApplicationView
    def initialize(@tenant : App::@@MODEL@@)
    end

    private def blueprint
      h1 { @tenant.name }
    end
  end
end
