module SugarORM::Catalog
  # SQL types are PostgreSQL format_type() spellings.
  record Column, name : String, sql_type : String, nullable : Bool, default : String?, primary : Bool = false, identity : Bool = false, renamed_from : String? = nil
  record Index, name : String, columns : Array(String), unique : Bool = false
  record ForeignKey, name : String, column : String, references_table : String, references_column : String = "id", on_delete : String = "NO ACTION"
  record Table, name : String, columns : Array(Column), indexes : Array(Index) = [] of Index, foreign_keys : Array(ForeignKey) = [] of ForeignKey, drops : Array(String) = [] of String

  # All concrete schemas in the program, sorted by table name; each is `T.__sugar_table`.
  # The body is expanded only when called, so requiring this file alone (as
  # Frappé does for the records) does not require the schema runtime.
  def self.declared : Array(Table)
    tables = [] of Table
    {% for schema in ::SugarORM::Schema.all_subclasses %}
      {% unless schema.abstract? %}
        tables << {{schema}}.__sugar_table
      {% end %}
    {% end %}
    tables.sort_by!(&.name)
  end
end
