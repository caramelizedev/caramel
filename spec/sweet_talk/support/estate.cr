# A tea estate whose contexts span files (ADR 0065): each context's header in a file of
# its own, each aggregate in its own file inside `within`, a specification in a later
# block than the query that reads it, a once_by unit in a `within`, and events logged from
# both a header and a `within`.
require "../../../src/caramel/sweet_talk"

module Estate
  include SweetTalk
  ids Int64
end

# The domain module requires each file after those whose names it uses.
require "./estate/garden"
require "./estate/garden/bush"
require "./estate/picking"
require "./estate/picking/basket"
require "./estate/picking/heavy"
