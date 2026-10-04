require "db"
require "../../sugar_orm"
require "../html"

module Caramel::Crema
  # Rows of text under named columns: what `jobs`, `db diagnose` and the ops
  # console print. Every column is read as text, so the SQL casts what it selects.
  record Table, headers : Array(String), rows : Array(Array(String)) do
    # Runs *sql* on *db*, or on SugarORM's current database.
    def self.query(sql : String,
                   args : Array(SugarORM::Value) = [] of SugarORM::Value,
                   db : DB::Database? = nil) : Table
      return read(sql, args) unless db

      SugarORM::Repo.using(db) { read(sql, args) }
    end

    private def self.read(sql : String, args : Array(SugarORM::Value)) : Table
      SugarORM::Repo.query(sql, args) do |rows|
        names = rows.column_names
        data = [] of Array(String)
        # A block inside `each` that reads `rows` crashes the compiler (1.21.1).
        rows.each { data << cells(rows, names.size) }
        new(names, data)
      end
    end

    private def self.cells(rows : DB::ResultSet, count : Int32) : Array(String)
      row = Array(String).new(count)
      while row.size < count
        row << (rows.read(String?) || "")
      end
      row
    end

    def empty? : Bool
      rows.empty?
    end

    # Columns aligned with two spaces between them, `(none)` when no row matched.
    def to_text : String
      return "(none)" if rows.empty?

      widths = headers.map_with_index do |name, index|
        {name.size, rows.max_of(&.[index].size)}.max
      end
      lines = [headers] + rows
      lines.join('\n') do |line|
        line.map_with_index { |cell, index| cell.ljust(widths[index]) }.join("  ").rstrip
      end
    end

    def to_html : String
      return "<p>None.</p>" if rows.empty?

      head = headers.join { |name| "<th>#{HTML.escape(name)}</th>" }
      body = rows.join { |row| "<tr>#{row.join { |cell| "<td>#{HTML.escape(cell)}</td>" }}</tr>" }
      "<table><thead><tr>#{head}</tr></thead><tbody>#{body}</tbody></table>"
    end
  end
end
