module App
  struct Book < SugarORM::Schema
    schema "books" do
      field id : Int64, primary: true
      field title : String
      field author : String
      field lock_version : Int32, version: true
      timestamps
    end
  end
end
