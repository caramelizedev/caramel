require "./application_record"

class Unsupported < ApplicationRecord
  table :unsupported
  field id : Int64?, primary: true
  field labels : Array(String)
end
