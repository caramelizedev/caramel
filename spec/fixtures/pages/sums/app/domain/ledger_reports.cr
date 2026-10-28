# The one report the Books context cannot state: a GROUP BY across periods. It lives
# outside the context, so it names a table and its columns, and it writes the tenant
# predicate out, because SugarORM.sql is not tenant-scoped.
module App::Ledger::Reports
  BY_HEADING = <<-SQL
    SELECT slot_heading AS heading, sum(total)::bigint AS total
    FROM books_balances
    WHERE account_id = $1
    GROUP BY slot_heading
    ORDER BY slot_heading
    SQL

  # What each heading was posted over every period, for the bound tenant only.
  def self.by_heading : Array({heading: String, total: Int64})
    SugarORM.sql(BY_HEADING, Caramel::Tenancy.current.id, as: {heading: String, total: Int64})
  end
end
