# Volt::RepoCache

- Provides client-side caching of repository (db) collections, models and their associations.
- Loads multiple associated collections (or query based subsets) into a cache.
- Buffers changes to models, collections and associations until flushed.
- Allows for flushes to be performed at model, collection or cache level.
- Provides increased associational integrity.
- Reduces the burden of promise handling in repository (db) operations.
- Is ideal for use where multiple associated models are being displayed and edited.
- Preserves standard Volt model and collection interfaces and reactivity.
 
## Installation

Add this line to your application's Gemfile:

    gem 'volt-repo_cache'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install volt-repo_cache

## Usage

Assume we have a sales application with three model classes:

    class Customer < Volt::Model
      field :name
      has_many :orders
    end
        
    class Product < Volt::Model
      field :name
      field :price
      has_many :orders
    end
        
    class Order < Volt:Model
      belongs_to :customer
      belongs_to :product
      field :date
      field :quantity
    end

Let's say we want to cache all customers, products,
and orders, the latter between some given dates.

The following code will create the cache and load it
in a controller's `index` method. We'll also add a 
`before_index_remove` method to clear the cache
when leaving the page.

#### Example 1 - defining and loading a cache

    class OrderController < Volt::ModelController

      def index
        new_cache.loaded.then do |cache|
          page._cache = cache
        end.fail do |errors|
          flashes << errors.to_s
        end
      end
      
      def new_cache
        Volt::RepoCache.new(
          Volt.current_app.store,
          customer: { 
            has_many: :orders,
          }
          product:  {
            has_many: :orders, 
          }
          order: { 
            belongs_to: [:customer, :product] 
            where: {'$and' => [:date => {'$gte' => start_date}, :date => {'$lte' => end_date}]} 
          }
        )
      end
    
      def before_index_remove
        page._cache.clear if _cache
      end
    
      ...
    end

**Under Volt 0.9.7 the specification of associations
will be provided by the underlying models' class
definitions and will no longer be required in 
the cache options.**

In the `index` method we only need to resolve
one promise when the cache is `loaded`. 

Collections may be identified in the singular or plural
according to preference, e.g. `order:` or `orders:`,
with or without an underscore prefix.

A `where:` or `query:` option may be provided for each collection
to specify which models are loaded from the repository.
The default behaviour is to load all models in a collection.

Resolution of associations between cached models will
depend on what has been loaded into the cache for
each collection. 

After the cache is loaded you can then access 
collections, models and associations without 
handling promise resolution or failure. 

Otherwise, the interfaces to cached models and collections
largely behave as normal.

#### Example 2 - query and association resolution

    # find all orders for customer 'ABC and product 'XYZ' 
    cache._customers.where(name: 'ABC').orders.select { |order|
      order.product.name == 'XYZ'
    }  

Unlike a standard Volt query and association call 
(`order.product`) we have no intervening promise(s) to
resolve, and also avoid relatively slow database request(s).

#### Example 3 - query and association resolution

    # total cost of products ordered by customer
    customer = cache._customers.where(name: 'ABC')
    total_cost = customer.orders.reduce(0) do |sum, order|
      sum + (order.quantity * order.product.price)
    end

Again, no promises to resolve and faster calculation of
total cost than would be the case with uncached database
access.

### Changes and flushing

Changes to field values in models are buffered until
flushed (saved) to the database. Flushes may be requested
at the model, collection or cache level. Each flush
returns a single promise. Some examples:

#### Example 4 - change and save a single model

    # change the price of a product and save it
    product = cache._products.where(name: 'XYZ')
    product.price = 9.99
    # flush the product model
    product.flush!.then do |result|
      puts "#{result} saved"
    end.fail do |errors|
      puts errors
    end
    
#### Example 5 - change and save several models in a collection

    # change the price of multiple products
    # and save them all together
    products = cache._products
    products.where(name: 'X').price = 7.77
    products.where(name: 'Y').price = 8.88
    products.where(name: 'Z').price = 9.99
    # flush the 'products' collection
    products.flush!.then do |result|
      puts "all products saved"
    end.fail do |errors|
      puts "error saving products: #{errors}"
    end
    
#### Example 6 - change and save models in more than one collection
    
    # change the price of a product
    # and the name of a customer
    # and save them together
    cache._products.where(name: 'XYZ').price = 7.77
    cache._customer.where(name: 'ABC').name = 'EFG'
    # flush the whole cache 
    cache.flush!.then do |result|
      puts "cached flushed successfully"
    end.fail do |errors|
      puts "error flushing cache: #{errors}"
    end
   
### Creating new models with no owners
   
There are two ways to create a new instance of a model
not belonging to another model:
 
#### Example 7 - create a new model (with no owner) via a collection

    # create a new product
    p = Product.new(name: 'IJK')
    cache._products << p
    
A new model must be added to the appropriate cached collection 
(using `#<<` or `#append`) before it also is cached. It will 
not be saved to the database until the model or its containing
collection or cache is flushed.

NB Both `#<<` and `#append` return the collection, not the
appended model. 

Another way of creating a new model via a collection using a hash:
 
#### Example 8 - create a new model (with no owner) via a collection

    # create a new product
    cache._products << {name: 'IJK'}
    p = cache._products.where(name: 'IJK')
        
### Creating new models with owners

When creating a new model which belongs to one or more models
you must set the foreign key id(s) to establish the association(s).

#### Example 9 - create a new model (with two owners) via a collection

    # create a new order which belongs to a customer and a product
    product = cache._products.where(code: 'XYZ')
    customer = cache._customers.where(code: 'ABC')
    order = Order.new(product_id: product.id, customer_id: customer.id, quantity: 1, date: Date.today)
    cache._orders << order
  
An easier way is ask an owner model to create a new owned model:
    
#### Example 10 - create a new model (with two owners) via an owner model
    
    product = cache._products.where(code: 'XYZ')
    customer = cache._customers.where(code: 'ABC')
    # ask the customer to create a new order, give it the product id
    order = customer.new_order(product_id: product.id, quantity: 1, date: Date.today)
    
### Destroying models
 
Models in the cache can be marked for destruction when the cache is flushed using `#mark_for_destruction!`.
Still to do - associational integrity checks when marking for destruction.
   
## Warnings

**Flushes to the underlying repository are not atomic and cannot be rolled back**. 
If part of the cache/collection/model/association 
flush fails the transaction(s) may lose integrity.

The cached models and collections contain circular references
(the models refer to the collection which contains them and 
collections refer to the cache). Not being sure what the 
implications are for efficient garbage collection (in Ruby
on the server and Javascript on the client), a method 
is provided to clear the cache when it is no longer required,
breaking all internal (circular) references.

## TODO

1. Use associations_data in Volt::Models when 0.9.7 (sql) version available.
2. Handle non-standard collection, foreign_key and local_key Volt model options. 
3. Association integrity checks on mark_for_destruction!
4. Test spec.
5. Locking?
6. Atomic transactions?
7. Removal of circular references?

## Contributing and use

This gem was written as part of the development of a production 
application, primarily to speed up processing requiring many 
implicit database queries (across associated collections), as well
as simplifying association management and reducing the burden of
asynchronous promise resolution.

It works well enough for our current application's needs, 
but it may not be suitable for all requirements.

We will look at extending the cache framework to support locking and
atomic transactions (with rollback), but in the meantime if you have
a need or interest in this area your suggestions and contributions
are very welcome.

To contribute:

1. Fork it ( http://github.com/[my-github-username]/volt-repo_cache/fork )
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create new Pull Request

## License

Copyright (c) 2015 Colin Gunn

MIT License

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
