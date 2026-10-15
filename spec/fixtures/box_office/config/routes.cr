    get "/shows/:show", App::Shows::Show
    post "/shows/:show/holds", App::Holds::Create
    get "/shows/:show/holds/:hold", App::Holds::Show
    post "/shows/:show/holds/:hold/sale", App::Holds::Sell
    post "/shows/:show/waitlist", App::Waitlists::Join
