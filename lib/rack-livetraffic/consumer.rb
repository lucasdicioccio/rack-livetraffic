
require 'ffi-rzmq'
require 'rack-livetraffic'
require 'rack-livetraffic/request_report'

module Rack
  module LiveTraffic
    # a Consumer is the SUB part of a ZMQ pubsub
    # abstracts the listening of reports
    class Consumer
      Message = Struct.new(:topic, :rack_id, :json)

      attr_reader :ctx, :sub
      def initialize(pfx='report', addr='tcp://localhost:5556', type=:sub)
        @ctx = ZMQ::Context.new
        @sub = case type
               when :sub
                 ctx.socket ZMQ::SUB
               when :pull
                 ctx.socket ZMQ::PULL
               else
                 raise ArgumentError, "not allowed publisher type:#{type}"
               end
        if type == :sub
          sub.connect addr
          key = LiveTraffic.key pfx
          sub.setsockopt ZMQ::SUBSCRIBE, key
        else
          sub.bind addr
        end
      end

      def next
        topic = ''
        sub.recv_string topic

        rack_id = ''
        sub.recv_string rack_id if sub.more_parts?

        json = ''
        sub.recv_string json if sub.more_parts?

        m = Message.new(topic, rack_id, json) 
        yield m if block_given?

        m
      end

      def each
        catch :halt do
          loop { yield self.next }
        end
      end
    end
  end
end
