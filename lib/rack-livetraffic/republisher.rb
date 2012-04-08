
require 'rack-livetraffic/consumer'
require 'rack-livetraffic/publisher'
module Rack
  module LiveTraffic
    # Republisher republishes the messages coming from multiple 
    # Rack::LiveTraffic::Middleware
    class Republisher
      def initialize(cfg={})
        pull_cfg = cfg[:pull] || 'tcp://*:5555'
        push_cfg = cfg[:publish] || 'tcp://*:5556'
        @pull = Consumer.new('report', pull_cfg, :pull)
        @pub  = Publisher.new('publisher', push_cfg, :pub)
      end

      def run
        @pull.each do |msg|
          yield msg if block_given?
          @pub.publish msg.rack_id, msg.json
        end
      end
    end
  end
end
