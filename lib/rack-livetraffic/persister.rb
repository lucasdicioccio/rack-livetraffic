
require 'rack-livetraffic'
require 'rack-livetraffic/consumer'
require 'rack-livetraffic/request_report'
require 'rack-livetraffic/stat_report'
require 'redis'

module Rack
  module LiveTraffic

    # Listen for any report item and dumps them in a redis database.
    class Persister
      attr_reader :consumer, :ttl, :randmax

      # Creates a new persister, all cfg are optional.
      #
      # cfg parameter:
      #  - :redis    => an array of parameters send to Redis.new
      #  - :ttl      => duration to persist keys in database (in secs)
      #  - :randmax  => maximum int when a key needs some random bits
      #                (defaults to 65535, i.e. 16bits) 
      #                may have collisions if you have too many keys per second
      #                and not enough bits
      def initialize(cfg={})
        consumer_cfg= cfg[:consumer] || []
        @consumer   = Consumer.new *consumer_cfg
        @ttl        = cfg[:ttl] || 30
        @randmax    = cfg[:randmax] || 65535
        redis_cfg   = cfg[:redis] || []
        @redis      = Redis.new *redis_cfg
      end

      # enters an infinite loop
      # an optional block may be passed, if so, te block will be called
      # for each item, before persisting it
      # the block can either:
      # - return :skip to not persist the item
      # - return anything else to persist the item
      # - throw :halt to break the infinite loop (will also skip)
      def run(&blk)
        consumer.each{|i| item_received(message_to_item(i), &blk)}
      end

      # stores an item in redis and sets it to expire when it 
      # won't be needed anymore
      def item_received(item)
        k = key(item)
        v = item.json
        skip = nil
        skip = yield k,v if block_given?
        unless :skip == skip
          @redis.multi do
            @redis.set k, v
            @redis.expire k, ttl
          end
        end
      end

      def message_to_item(m)
        m
      end

      def key(item)
        raise NotImplementedError
      end
    end

    class HttpPersister < Persister
      # generates a key for a report item:
      # x.y.z.z'
      # * x  => a livetraffic prefix
      # * y  => an optional rack_id (i.e., may be an empty string)
      # * z  => the item timestamp in seconds
      # * z' => a random value on 16 bits (default)
      def key(item)
        LiveTraffic.key 'report', item.rack_id, item.start, rand(randmax).to_i
      end

      def message_to_item(m)
        RequestReport.new(m.rack_id, m.json)
      end
    end

    class StatsPersister < Persister
      def message_to_item(m)
        StatReport.new(m.rack_id, m.json)
      end

      def key(item)
        LiveTraffic.key 'stats', item.key, item.rack_id, item.date
      end
    end
  end
end
