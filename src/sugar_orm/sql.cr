module SugarORM
  # Runs hand-written SQL (CTEs, window functions, RETURNING) on the current
  # Repo connection and reads each row as a NamedTuple:
  #
  #     query = "SELECT team_id, count(*) AS total FROM users GROUP BY team_id"
  #     SugarORM.sql(query, as: {team_id: Int64, total: Int64})
  #     # => Array(NamedTuple(team_id: Int64, total: Int64))
  #
  # The result columns must equal the `as:` keys, in order, or it raises ShapeError.
  def self.sql(query : String, *args, as types : NamedTuple)
    columns = types.keys.map(&.to_s).to_a
    Repo.query(query, bind(args)) do |rows|
      actual = rows.column_names
      raise shape_error(columns, actual) unless actual == columns
      results = [] of typeof(rows.read(**types))
      rows.each { results << rows.read(**types) }
      results
    end
  end

  def self.sql(db : Handle, query : String, *args, as types : NamedTuple)
    Repo.using(db) { sql(query, *args, as: types) }
  end

  # Runs a statement on the current Repo connection and returns the number of
  # rows affected.
  def self.sql_exec(query : String, *args) : Int64
    Repo.exec(query, bind(args)).rows_affected
  end

  def self.sql_exec(db : Handle, query : String, *args) : Int64
    Repo.using(db) { sql_exec(query, *args) }
  end

  private def self.bind(args : Tuple) : Array(Value)
    values = [] of Value
    args.each { |arg| values << arg }
    values
  end

  private def self.shape_error(columns : Array(String),
                               actual : Array(String)) : ShapeError
    ShapeError.new(
      "SugarORM.sql expected columns (#{columns.join(", ")}) " \
      "but the query returned (#{actual.join(", ")}).\n" \
      "Remediation: alias the selected columns with AS " \
      "so they match the `as:` keys in order."
    )
  end
end
