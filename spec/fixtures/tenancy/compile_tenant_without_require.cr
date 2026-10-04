require "../../../src/caramel"

module Fixture
  struct Account < SugarORM::Schema
    schema "accounts" do
      field id : Int64, primary: true
      field slug : String
    end
  end

  struct Book < SugarORM::Schema
    schema "books" do
      field id : Int64, primary: true
      tenant account : Account
    end
  end
end
