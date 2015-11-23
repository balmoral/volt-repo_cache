# Volt::RepoCache

- Provides client-side caching of repository collections, models and their associations.
- Extends the principle of a Volt model buffer across multiple collections and models for any Volt repository.
- Loads multiple associated collections (or query based subsets) into a cache.
- Requires only one promise to resolve on loading. Once loaded there are no more promises to resolve.
- Allows models (via their cached proxies) to be added, updated and marked for destruction.
- Caches changes until explicitly saved (flushed) to the repository.
- Allows for flushes to be performed at model, collection or cache level.
- Requires only one promise to handle when flushing the cache to the repository.
- Is ideal for use where associated models are being displayed and edited.
- Preserves model and collection interfaces and reactivity.
 
## Installation

Add this line to your application's Gemfile:

    gem 'volt-repo_cache'

And then execute:

    $ bundle

Or install it yourself as:

    $ gem install volt-repo_cache

## Usage

Assume we have a sales application with four model classes:

    class Customer < Volt::Model
      field :name
      has_one :contact
      has_many :orders
    end
        
    class Contact < Volt::Model
      field :phone
      belongs_to :customer
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

Let's say we want to cache all customers, contacts and products, 
and orders between given dates. The following code will create 
the cache and load it (in a controller's `index` method). 
We'll also add a `before_index_remove` method to clear the cache 
when leaving the page.

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
            has_one: :contact, 
            has_many: :orders,
          }
          contact:  { 
            belongs_to: :customer, 
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

In the `index` method we only need to resolve
one promise when the cache is `loaded`. 

**Under Volt 0.9.7 the specification of associations
in the cache will not be necessary.**

Collections may be identified in the singular or plural
according to preference, e.g. `order:` or `orders`,
with or without an underscore prefix.

A `where:` option may be provided for each collection
to specify which models are loaded from the repository.
The default behaviour is to load all models in the collection.

Resolution of associations between cached models will
depend on what has been loaded into the cache for
each collection. 

After the cache is loaded you can then access 
collections, models and associations without 
needing to wait for promises to resolve or 
needing to handle promise failures.
Everything is cached in memory and ready to go
(unless there were failures in the initial 
cache `loaded` promise).

The interfaces to cached models and collections 
behave as normal, except that results from association 
methods are returned without a promise.

Some examples of using associations:

    # collate customer names and contacts
    cache._customers.collect do |customer|
      {
        name: customer.name,
        phone: customer.contact.phone
      }
    end

Without caching the simple association 
`customer.contact` above would require a promise to resolve,
complicating the code and (if from the `store` repo)
being a relatively slow database query. 

    # total cost of products ordered by a customer
    total_cost = customer.orders.inject(0) do |sum, order|
      sum + (order.quantity * order.product.cost)
    end

Again, without caching the simple association 
`order.product` above would require a promise to resolve
and a potentially slow database query. 
   
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
2. Further documentation and examples, especially for setting associations.
3. Handle non-standard collection, foreign_key and local_key options. 
4. Test spec.
5. Locking?
6. Atomic transactions?
7. Removal of circular references?

## Contributing and use

This gem was written as part of the development of a production application.
As it simplifies implementation around asynchronous promise resolution
in Volt (common to client-side processing in general), we thought it
might be helpful to other Volt developers.

If nothing else, the implementation here may provide a working (if not perfect) 
example of promise chaining and collation. If you're still trying to
get your head around handling promises, take a look at the code here.
This is the author's attempt at hiding common promise handling around
database queries and associations in a `DRY` black box. It works well 
enough for our current application's needs, but it may not scale 
well - particularly where transactional integrity is paramount.
We will look at extending the cache framework to support locking and
atomic transactions (with rollback), but in the meantime if you have
a need or interest in this area your suggestions and contributions
would be welcome.

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
