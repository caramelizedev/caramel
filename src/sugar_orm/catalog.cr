module SugarORM::Catalog
  # SQL types are PostgreSQL format_type() spellings.
  record Column,
    name : String,
    sql_type : String,
    nullable : Bool,
    default : String?,
    primary : Bool = false,
    identity : Bool = false,
    renamed_from : String? = nil

  record Index, name : String, columns : Array(String), unique : Bool = false

  # The name of the index on *columns* of *table*: `index_<table>_on_<a>_and_<b>`, or over
  # PostgreSQL's 63 bytes `index_<table>_on_<cut>_<fnv8>`, the whole name's FNV-1a 32-bit
  # hash after the column list cut so the name fits. The schema macro builds the same
  # name at compile time, so the differ, the unique-violation mapping and the catalog agree.
  def self.index_name(table : String, columns : Enumerable(String)) : String
    name = "index_#{table}_on_#{columns.join("_and_")}"
    return name if name.bytesize <= 63
    "#{name[0, 54]}_#{fnv8(name)}"
  end

  # The FNV-1a 32-bit hash of *text*, as eight hex digits.
  def self.fnv8(text : String) : String
    hash = 2166136261_u32
    text.each_byte { |byte| hash = (hash ^ byte) &* 16777619_u32 }
    hash.to_s(16).rjust(8, '0')
  end

  record ForeignKey,
    name : String,
    columns : Array(String),
    references_table : String,
    references_columns : Array(String) = ["id"],
    on_delete : String = "NO ACTION"

  # A CHECK constraint. A range check bounds *column* by *min* and *max*
  # (either may be open); an expression check holds its SQL in *expression*,
  # as declared or as PostgreSQL prints it, and is compared by name only.
  record Check,
    name : String,
    column : String? = nil,
    min : Int64? = nil,
    max : Int64? = nil,
    expression : String? = nil

  record Table,
    name : String,
    columns : Array(Column),
    indexes : Array(Index) = [] of Index,
    foreign_keys : Array(ForeignKey) = [] of ForeignKey,
    drops : Array(String) = [] of String,
    checks : Array(Check) = [] of Check

  # All concrete schemas in the program, sorted by table name; each is `T.__sugar_table`.
  # The body is expanded only when called, so requiring this file alone (as
  # Frappé does for the records) does not require the schema runtime.
  def self.declared : Array(Table)
    tables = [] of Table
    {% for schema in ::SugarORM::Schema.all_subclasses %}
      {% unless schema.abstract? %}
        tables << {{ schema }}.__sugar_table
      {% end %}
    {% end %}
    tables.sort_by!(&.name)
  end
end
