require "../../../src/caramel/sweet_talk"

module Rules
  include SweetTalk

  context Shelf, means: "a shelf for trying the rules" do
    value Count, Int32, at_least: 0, means: "how many things are in a box"

    aggregate Jar, means: "a jar of loose tea" do
      has label : String
      has count : Count
      has slots : Array(Slot)
      moves on_shelf >> sold_out

      entity Slot, means: "one place in a jar's rack" do
        has tea : String
      end

      finds wiped do |jars|
        jars.where("id > ?", SugarORM.sql_exec("DELETE FROM shelf_jars"))
      end
    end

    specification Full, on: Jar, where: {count: Count.new(5)..}, means: "a jar of five or more"
  end
end
