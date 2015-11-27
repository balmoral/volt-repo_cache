class Order < Volt::Model
  field       :date, String #YYYYMMDD
  field       :quantity, Fixnum
  belongs_to  :customer
  belongs_to  :product
end
