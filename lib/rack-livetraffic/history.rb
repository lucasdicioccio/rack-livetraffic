
require 'time'

module Rack
  module LiveTraffic
    # Handy class to work with time-bounded dataset of items.
    #
    # ArrayHistory implementation uses a simple array as a structure, this
    # should be enough for cheap ruby-frontends' loads.
    # It gives a good idea of what is the interface for History.
    #
    # HashHistory is a bit more efficient because it doesn't have to go
    # through all the results when splitting on the recent history.
    class History
      def replace(what)
        self.class.new what
      end
    end

    class HashHistory < History
      def initialize(items={})
        @items_hash = Hash.new{|h,k| h[k] = []}.merge! items
      end

      def items
        @items_hash.values.flatten
      end

      def keys
        @items_hash.keys
      end

      def << item
        @items_hash[item.date] << item
      end

      def recent(secs)
        t = Time.now.tv_sec - secs
        subset {|k| k >= t }
      end

      def subset
        kept_keys =  keys.select{|k| yield k}
        new_hash = {}
        kept_keys.each{|k| new_hash[k] = @items_hash[k]}
        replace new_hash
      end

      def empty?
        @items_hash.empty?
      end

      def merge_hash(hash)
        hash.each_pair do |k,v|
          @items_hash[k] = v
        end
        self
      end
    end

    class ArrayHistory < History
      attr_reader :items

      def initialize(items=[])
        @items = items
      end

      def << item
        @items << item
      end

      def recent(secs)
        t = Time.now.tv_sec - secs
        subset {|i| i.date >= t }
      end

      def empty?
        @items.empty?
      end

      def subset
        replace @items.select{|i| yield i}
      end
    end
  end
end
