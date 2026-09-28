module App
  # Every view's base: a Caramel::View (Blueprint) with the application's
  # path helpers.
  abstract class ApplicationView < Caramel::View
    include App::Paths
  end
end
