require "../../../src/sugar_orm"

struct Reservation < SugarORM::Schema
  schema "conference_room_reservations" do
    field id : Int64, primary: true
    field seats : Int32
    check :maximum_attendees_allowed_per_window, "seats < 100"
  end
end
