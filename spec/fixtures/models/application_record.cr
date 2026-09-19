require "../../../src/caramel/model"

abstract class ApplicationRecord < Caramel::Model
end

class TypedSample < ApplicationRecord
  table :typed_samples
  field name : String
  field id : Int64?, primary: true
  field quantity : Int32
  field total : Int64
  field active : Bool
  field score : Float64?
  field note : String?
  field published_at : Time?
  timestamps

  @presentation_cache : String = "not a database field"
end

class Book < ApplicationRecord
  table :typed_books

  field id : Int64?, primary: true
  field title : String
  field author : String
  timestamps
  validates :title, presence: true
end
