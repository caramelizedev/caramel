require "spec"
require "html"
require "../../../src/caramel/crema/sql_format"

private INSERT_QUOTE = <<-SQL.gsub('\n', ' ')
  INSERT INTO "rate_quotes" ("requested_on", "source_on", "base_currency", "quote_currency",
  "rate", "source", "evidence", "business_id") VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
  RETURNING "id", "business_id", "requested_on", "source_on", "base_currency", "quote_currency",
  "rate", "source", "evidence", "created_at", "updated_at"
  SQL

private JOINED = <<-SQL.gsub('\n', ' ')
  SELECT "rates".*, "currencies"."code" FROM "rates" LEFT JOIN "currencies"
  ON "currencies"."id" = "rates"."currency_id" WHERE "rates"."account_id" = $1
  AND "rates"."updated_at" BETWEEN $2 AND $3 OR "rates"."pinned" = $4
  ORDER BY "rates"."updated_at" DESC LIMIT $5
  SQL

private OWN_LAYOUT = <<-SQL
  SELECT relname, n_dead_tup
  FROM pg_stat_user_tables
  WHERE n_dead_tup > $1
  ORDER BY n_dead_tup DESC
  LIMIT 10
  SQL

private UPDATE_QUOTE = <<-SQL.gsub('\n', ' ')
  UPDATE "rate_quotes" SET "evidence" = $1, "updated_at" = $2 WHERE "rate_quotes"."id" = $3
  SQL

private BULK_ROWS = (0...8).map { |row| "($#{row * 3 + 1}, $#{row * 3 + 2}, $#{row * 3 + 3})" }
private BULK      = %(INSERT INTO "rate_rows" ("a", "b", "c") VALUES ) + BULK_ROWS.join(", ")

# The text of each line, without its markup.
private def lines(html : String) : Array(String)
  body = html.sub(%(<code class="sql">), "").sub("</code>", "")
  body.split(%(<span class="line)).skip(1).map do |chunk|
    ::HTML.unescape(chunk.sub(/\A[^>]*>/, "").gsub(/<[^>]+>/, ""))
  end
end

private def markup(text : String) : String
  Caramel::Crema::SqlFormat.html(text)
end

private def condition_lines(html : String) : Int32
  html.scan(%(<span class="line cond">)).size
end

describe Caramel::Crema::SqlFormat do
  it "puts each clause of a one-line statement on its own line" do
    shown = lines(markup(INSERT_QUOTE))

    shown.size.should eq(3)
    shown[0].should start_with(%(INSERT INTO "rate_quotes"))
    shown[1].should start_with("VALUES ($1")
    shown[2].should start_with(%(RETURNING "id"))
  end

  it "puts a condition on its own line, keeping BETWEEN … AND together" do
    html = markup(JOINED)
    shown = lines(html)

    shown.size.should eq(8)
    shown[0].should start_with(%(SELECT "rates".*))
    shown[1].should start_with(%(FROM "rates"))
    shown[2].should start_with(%(LEFT JOIN "currencies" ON))
    shown[3].should start_with("WHERE")
    shown[4].should eq(%(AND "rates"."updated_at" BETWEEN $2 AND $3))
    shown[5].should start_with(%(OR "rates"."pinned"))
    shown[6].should start_with("ORDER BY")
    shown[7].should eq("LIMIT $5")
    condition_lines(html).should eq(2)
    html.should contain(%(<span class="line cond"><span class="kw">AND</span>))
  end

  it "breaks only outside parentheses" do
    lines(markup("SELECT * FROM t WHERE id IN (SELECT x FROM y WHERE z = 1)")).size.should eq(3)
  end

  it "keeps a function call named like a clause on its line" do
    lines(markup("SELECT left(query, 200) FROM pg_stat_activity")).size.should eq(2)
  end

  it "keeps DELETE FROM together" do
    shown = lines(markup(%(DELETE FROM "t" WHERE "id" = $1)))

    shown.size.should eq(2)
    shown[0].should eq(%(DELETE FROM "t"))
  end

  it "keeps IS DISTINCT FROM together" do
    lines(markup("SELECT a FROM t WHERE b IS NOT DISTINCT FROM $1")).size.should eq(3)
  end

  it "leaves text inside strings and identifiers alone" do
    html = markup(%(SELECT 'a FROM b', "FROM" FROM t))

    lines(html).size.should eq(2)
    html.should contain(%(<span class="str">&#39;a FROM b&#39;</span>))
  end

  it "keeps the layout of a statement that has line breaks" do
    shown = lines(markup(OWN_LAYOUT))

    shown.size.should eq(5)
    shown.should eq(OWN_LAYOUT.split('\n'))
  end

  it "escapes the statement" do
    html = markup("SELECT '<b>'")

    html.should contain("&lt;b&gt;")
    html.should_not contain("<b>")
  end

  it "marks a placeholder but not a word that ends in one" do
    markup("SELECT a AS name$1, $1").scan(%(class="ph")).size.should eq(1)
  end

  it "loses no text" do
    statements = [INSERT_QUOTE, JOINED, OWN_LAYOUT, UPDATE_QUOTE, BULK,
                  "SELECT 'a FROM b', \"FROM\" -- note FROM\nFROM t /* x */ WHERE $$a$$ = $1"]

    statements.each do |sql|
      text = ::HTML.unescape(markup(sql).gsub(/<[^>]+>/, "")).gsub(/\s+/, "")

      text.should eq(sql.gsub(/\s+/, ""))
    end
  end
end
