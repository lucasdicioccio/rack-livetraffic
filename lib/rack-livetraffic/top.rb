require 'rack-livetraffic'
require 'rack-livetraffic/consumer'
require 'rack-livetraffic/publisher'
require 'rack-livetraffic/history'
require 'rack-livetraffic/statistics'

require 'thread'

module Rack
  module LiveTraffic
    class Top
      attr_reader :consumer, :period, :memory_size, :publisher, :slices, :multi_slices

      # A Slice is a tuple (rack_id, history, statistics) which combines, for one rack-id:
      # - the history of requests digest
      # - the history of statistics computations
      Slice = Struct.new(:rack_id, :history, :statistics) do
        # does this Top consider all items or only those coming from 
        # a given rack application?
        def keep_all?
          '' == rack_id
        end

        # whether or not an item is interesting given its rack_id
        def interesting_item?(item)
          item.rack_id == rack_id
        end

        # whether or not to keep an item based on this Top's rack_id filter
        # and the item's rack_id
        def keep_item?(item)
          keep_all? or interesting_item?(item)
        end

        def store_item(item)
          history << item
        end
      end

      # Initializes a new Top with optional config parameters.
      # cfg params:
      # - :id       => the rack's app livetraffic.id to filter on
      # - :period   => rate in seconds at which this Top evaluates statistics
      # - :duration => duration in seconds of the history
      # - :reload   => an optional symbol to load data from a persistent 
      #               storage before going "live" (only support now :redis)
      def initialize(cfg={})
        @killed       = false
        @period       = cfg[:period] || 10
        @memory_size  = cfg[:duration] || 300
        loadmeths     = cfg[:reload] || []
        read_only     = cfg[:read_only] || false
        @multi_slices = cfg[:multi_slices] || false

        # a unique publisher to give to all statistics
        @publisher  = if read_only
                        FakePublisher.new
                      else
                        zmq = cfg[:publish] || 'tcp://*:5558'
                        Publisher.new 'top', zmq
                      end

        # a mutex protecting computing thread from data input thread
        @mutex      = Mutex.new

        # a set of slices plus a default slice
        @slices           = {}
        rack_id           = cfg[:rack_id] || ''
        add_slice_for_rack_id rack_id

        # load history
        loadmeths.each {|m| load_from m}

        # start receiving data
        zmq = cfg[:subscribe] ||  'tcp://localhost:5556'
        start_receiving!(zmq) unless read_only
      end

      def slice_for_rack_id(rack_id)
        history    = HashHistory.new
        stats = statistics_for_rack_id rack_id
        Slice.new(rack_id, history, stats)
      end

      def statistics_for_rack_id(rack_id)
        cfg = {:publisher => publisher, :rack_id => rack_id}
        [ Counter.new(cfg), 
          Rate.new(cfg), 
          SlowRequests.new(cfg), 
          UniqueVisitors.new(cfg), 
          HostnameStats.new(cfg), ]
      end

      # well, the title says all
      # btw, there's no way to ressucitate a Top, you'd rather create a new one
      def killed?
        @killed
      end

      # starts an infinite loop which periodically report statistics.
      #
      # A mandatory block will be called with each statistics object 
      # (a hash of the statistics computed).
      # Within the block, a user can also throw :kill to kill this Top.
      # Note that once a Top has been killed, you cannot restart it.
      def run(&blk)
        raise ArgumentError, "must pass a block argument" unless block_given?
        raise "#{self} was killed" if killed?
        consumer_thread
        top_loop(&blk)
        @killed = true
      end

      alias :multi_slices? :multi_slices

      private

      # starts to receive messages (not actually using them)
      def start_receiving!(zmq)
        @consumer   = Consumer.new('report', zmq)
      end

      # handy way to thread-protect this Top and either:
      # - call a block
      # - send a method
      #
      # cannot have both a sym and a block
      def access(sym=nil)
        if block_given?
          raise ArgumentError, "can't have a sym and a block" if sym
          @mutex.synchronize { yield }
        else
          @mutex.synchronize { send sym }
        end
      end

      # starts the infinite thread consuming the items
      def consumer_thread
        return unless consumer
        thread = Thread.new do
          consumer.each do |m| 
            i = RequestReport.new(m.rack_id, m.json)
            item_received i
          end
        end
        thread.abort_on_exception = true
      end

      # infinite loop to periodically compute stats
      def top_loop(&blk)
        catch :kill do
          loop do
            top_iteration(&blk)
          end
        end
      end

      # computes stats once
      def top_iteration
        forget_past! 
        t0 = Time.now
        dat = compute
        t1 = Time.now
        dat.merge!('.time.total' => t1-t0) if $DEBUG
        yield dat if block_given?
        sleep period
      end

      # react to an item and throws :kill if the Top was killed already
      #
      # this :kill allows to end the consumer thread more cleanly than when
      # this Top gets garbage collected
      def item_received(item)
        access do 
          throw :kill if killed?

          rack_id = item.rack_id
          if multi_slices? and (not has_slice_for_rack_id?(rack_id))
            add_slice_for_rack_id(rack_id) 
          end

          slices.values.each do |slice|
            slice.store_item item if slice.keep_item?(item) 
          end
        end
      end

      def add_slice_for_rack_id(rack_id)
        slices[rack_id] = slice_for_rack_id rack_id 
      end

      def has_slice_for_rack_id?(rack_id)
        slices[rack_id]
      end

      # unprotected way to filter out the too-old items in history 
      #
      # unsafe in the sense that an item_received in
      # parallel may fall in the "old" history object
      def unsafe_forget_past!
        slices.values.map(&:history).each{|h| h.recent(memory_size)}

        if multi_slices?
          to_delete = slices.values.reject{|s| keep_slice?(s)}
          to_delete.map(&:rack_id).map do |rack_id| 
            slices.delete(rack_id)
          end
        end
      end

      def keep_slice?(slice)
        (not slice.history.empty?) or slice.keep_all?
      end

      # safe way to all unsafe_forget_past!
      def forget_past!
        access :unsafe_forget_past!
      end

      def compute
        ret = {}
        slices.values.each do |s|
          ret[s.rack_id] = compute_statistics_for_slice(s)
        end
        ret
      end

      # computes statistics based on current history for a slice
      def compute_statistics_for_slice(slice)
        ret = {}
        stats  = slice.statistics
        history     = slice.history
        stats.each do |stat|
          k = stat.key
          k2 = ".time.#{k}"
          t0 = Time.now
          ret[k] = stat.compute(history, memory_size)
          t1 = Time.now
          ret[k2] = (t1 - t0) if $DEBUG
        end
        ret
      end

      # calls a method load_from_<*> and forward args and block
      def load_from(m, *args, &blk)
        return if :nothing == m
        meth = "load_from_#{m}".to_sym
        if private_methods.include?(meth) or respond_to?(meth)
          send meth, *args, &blk 
        else
          raise NoMethodError, "#{m} is not a proper loader"
        end
      end

      # unpretty method that does the job to load into memory all items 
      # that are stored in Redis
      #
      # see Persister for more
      def load_from_redis_http
        require 'redis'
        redis = Redis.connect
        reload_http_from_redis redis
      end

      def load_from_redis_stats
        require 'redis'
        redis = Redis.connect
        slices.values.each do |slice|
          reload_slice_from_redis redis, slice
        end
      end

      def reload_slice_from_redis(redis, slice)
        slice.statistics.each do |stat|
          reload_stats_from_redis(redis, slice, stat)
        end
      end

      def reload_stats_from_redis(redis, slice, stat)
        key = stat.key
        pattern = LiveTraffic.key('stats', key, slice.rack_id, '*')

        ary = load_redis_keys_for_pattern redis, pattern
        stat.restore_computation_from_jsons ary
      end

      def reload_http_from_redis(redis)
        slices.values.each do |slice|
          reload_slice_http_from_redis redis, slice
        end
      end

      def reload_slice_http_from_redis(redis, slice)
        # http requests are partitioned per rack_id,
        # if you want all rack_ids, you need to handle the
        # keep_all? case separately 
        # (we need to read all rack_ids plus no rack_ids)
        pattern = if slice.keep_all?
                    LiveTraffic.key('report', '*')
                  else
                    LiveTraffic.key('report', slice.rack_id, '*')
                  end

        ary = load_redis_keys_for_pattern redis, pattern
        
        ary.each do |json|
          item = RequestReport.new(nil, json)
          #XXX one could use the rack_id variable directly because we do not
          #    really care about the rack-id in the statistics for dimelo's
          #    contest
          #
          #    however, if one wants to add a new statistics using that, it's
          #    better to have a correct value :]
          item.rack_id = item.body['rack-id'] 
          slice.store_item item
        end
      end

      def load_redis_keys_for_pattern(redis, pattern)
        keys  = redis.keys pattern
        redis.multi do
          keys.each do |k|
            redis.get k
          end
        end.compact
      end

    end
  end
end
