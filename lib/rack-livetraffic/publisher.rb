
require 'ffi-rzmq'

module Rack
  module LiveTraffic
    class FakePublisher
      def publish(*args,&blk)
      end
    end

    # a Publisher is the PUB part of a ZMQ pubsub
    # it abstracts the publication of digest reports
    class Publisher
      attr_reader :ctx, :pub
      def initialize(identity='livetraffic', bindaddr='tcp://*:5555', type=:pub)
        @ctx = ZMQ::Context.new
        @pub = case type
               when :pub
                 ctx.socket ZMQ::PUB
               when :push
                 ctx.socket ZMQ::PUSH
               else
                 raise ArgumentError, "not allowed publisher type:#{type}"
               end
        if type == :pub
          pub.bind bindaddr
          pub.identity = identity
        else
          pub.connect bindaddr
        end
      end

      def publish(rack_id, str, pfx='report')
        key = LiveTraffic.key pfx
        pub.send_string key, ZMQ::SNDMORE
        pub.send_string rack_id, ZMQ::SNDMORE
        pub.send_string str
      end
    end
  end
end
