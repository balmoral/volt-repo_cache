class Customer < Volt::Model
  field :name
  has_many :orders
end
