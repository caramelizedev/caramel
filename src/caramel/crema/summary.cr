module Caramel::Crema
  SQL_TABLE = /\b(?:FROM|INTO|UPDATE|JOIN)\s+"?([A-Za-z_][A-Za-z0-9_]*)/i

  # The SQL a statement runs, reduced to its verb and first table, such as
  # `SELECT books`. It never holds a bind value.
  def self.summary(sql : String) : String
    verb = sql.lstrip.partition(' ')[0].upcase
    table = SQL_TABLE.match(sql).try(&.[1])
    table ? "#{verb} #{table}" : verb
  end
end
