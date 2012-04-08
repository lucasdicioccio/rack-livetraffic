
class Struct
  def to_json(*args)
    to_a.to_json
  end
end

require 'digest/sha1'
module Rack
  module LiveTraffic
    # Top class for Statistics.
    # Statistics have a key (e.g., to be used in the JSON reports) and 
    # may have a config.
    class Statistics
      class << self
        def inherited(klass)
          klass.key klass.name.downcase.split('::').last
        end
        def key(val=nil)
          @key = val if val
          @key
        end
      end

      # A publisher to publish results
      attr_reader :pub

      # An indicative rack_id if this statistics operates on 
      # a given rack_id, useful for publishing
      attr_reader :rack_id

      # An History of computations
      attr_reader :history

      # A timed computation result
      Computation = Struct.new(:date,:key, :result)

      # sets the config by merging the default config with cfg hash parameter
      # all config keys must be valid attr_accessors
      # can also take a :publisher to publish results
      def initialize(cfg={})
        params = default.merge(cfg)
        @pub      = params.delete(:publisher)
        @rack_id  = params.delete(:rack_id)
        #remaining parameters
        params.each_pair{|k,v| self.send("#{k}=",v)}
        @history = HashHistory.new
      end

      # default config, subclass me if you want
      def default
        {:rack_id => ''}
      end

      # pseudo map-reduce function:
      # - break down items into groups based on their "key" 
      # - then reduce all groups using the block parameter
      def aggregate(items, key)
        ret = {}
        items.group_by(&key).each_pair do |k,ary|
          ret[k] = yield k, ary
        end
        ret
      end

      # whether or not there is a publisher
      def publishes?
        pub
      end

      # subclass if the key is not the class' key 
      # (e.g., for use into JSON reports)
      def key
        self.class.key
      end

      # must be implemented in subclassed
      # hist: the items as an History object
      # duration: an indicative value of the duration of the hist
      def compute(hist, duration)
        hist = needed_computations_subset(hist)

        computations = aggregate_computations hist do |date,ary|
          compute_result date, ary
        end

        publish_computations computations.values if publishes?
        cache_computations computations
        forget_past!(duration)
        reduce_computations @history.items
      end

      def cache_computations(computations)
        @history.merge_hash computations
      end

      def restore_computation_from_jsons(jsons)
        ary = jsons.map{|json| JSON.parse json}
        restore_computation_from_objects ary
      end

      def restore_result(obj)
        obj
      end

      def restore_computation_from_objects(aries)
        computations = aries.map do |pair|
          date,key, result = *pair
          Computation.new date,key,restore_result(result)
        end
        restore_computations computations
      end

      def restore_computations(computations)
        hash = computations.group_by(&:date)
        cache_computations hash
      end

      def publish_computations(computations)
        computations.each do |c|
          pub.publish rack_id, c.to_json, 'stats'
        end
      end

      def forget_past!(duration)
        @history = @history.recent(duration)
      end

      def needed_computations_subset(hist)
        keys = @history.keys.sort
        #forget the five first samples because new samples
        #  may have arrived:
        #  - clock desynchro
        #  - propagation time in the pub/sub
        keys = keys.slice(0, keys.size-5) || []

        hist.subset { |k| not keys.include?(k) }
      end

      def aggregate_computations(hist)
        # not the fatest way to do it, but should be enough
        aggregate(hist.items, :date) do |date,ary|
          result = yield date, ary
          Computation.new(date, key, result)
        end
      end

      def compute_result(date,items)
        raise NotImplementedError
      end

      def reduce_computations(computations)
        raise NotImplementedError
      end
    end

    # Counts the number of requests.
    class Counter < Statistics
      key 'requests'
      def compute_result(date,items)
        items.size
      end
      def reduce_computations(computations)
        computations.map(&:result).inject(&:+) || 0
      end
    end

    # Average number of requests per second.
    class Rate < Statistics
      def compute_result(date,items)
        items.size
      end

      def reduce_computations(computations)
        if computations.any?
          t0 = computations.map(&:date).min
          t1 = Time.now.tv_sec
          delta_t = t1 - t0
          computations.map(&:result).inject(&:+).to_f / delta_t
        else 
          0
        end
      end
    end

    class SlowRequests < Statistics
      key 'slow_requests'
      #number of slow requests to report
      attr_accessor :number

      def default
        super.merge({number:10})
      end

      def slow_items(items)
        items.flatten.sort_by{|n| 0 - n.lifetime}.slice(0, number) || []
      end

      Info = Struct.new(:url, :lifetime)

      def restore_result(ary)
        pair = ary.first
        Info.new(*pair)
      end

      def compute_result(date,items)
        slow_items(items).map{|r| Info.new(r.url, r.lifetime)}
      end

      def reduce_computations(computations)
        slow_items(computations.map(&:result)).map do |i| 
          {i.url => i.lifetime}
        end
      end
    end

    # number of unique visitors taking into account:
    # - an optional identifying cookie
    # - the (IP,user-agent) tuple (to better identify behind NATs)
    # see RequestReport#token
    class UniqueVisitors < Statistics
      key 'uniq_visitor'
      def user_tokens(items)
        items.flatten.map(&:token).uniq
      end

      Info = Struct.new(:token)
      def restore_result(ary)
        Info.new ary.first
      end

      def compute_result(date,items)
        user_tokens(items).map{|t| Info.new t}
      end

      def reduce_computations(computations)
        user_tokens(computations.map(&:result)).uniq.size
      end
    end

    #per-hostname number of requests plus per-path break-down
    class HostnameStats < Statistics
      key 'hostnames'
      Info = Struct.new(:stats) do
        def each_host(&blk)
          stats.each_pair(&blk)
        end
      end

      def restore_result(ary)
        Info.new ary.first
      end

      def compute_result(date,items)
        stats = aggregate(items, :host) do |host,ary|
          host_stats ary
        end
        Info.new stats
      end

      def reduce_computations(computations)
        ret = Hash.new {|h,k| h[k] = host_stats([])}
        computations.each do |computation|
          computation.result.each_host do |host,stats|
            ret[host]['total'] += stats['total']
            stats['paths'].each_pair do |path,count|
              ret[host]['paths'][path] ||= 0
              ret[host]['paths'][path] += count
            end
          end
        end
        ret
      end

      def path_stats(reqs)
        aggregate(reqs, :path) do |path, items|
          items.size
        end
      end

      def host_stats(reqs)
        {
          'total' => reqs.size,
          'paths' => path_stats(reqs)
        }
      end
    end
  end
end
