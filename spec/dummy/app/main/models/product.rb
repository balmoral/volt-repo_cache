class Product < Volt::Model
  field :name, String
  has_many :orders
end

