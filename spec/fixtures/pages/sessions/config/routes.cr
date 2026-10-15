    get "/login", App::Sessions::New
    post "/login", App::Sessions::Login
    post "/logout", App::Sessions::Logout
