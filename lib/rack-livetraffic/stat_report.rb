
require 'json'
module Rack
  module LiveTraffic

    StatReport = Struct.new(:rack_id, :json) do
      def initialize(*args,&blk)
        super
        @data = nil
      end
      def data
        @data ||= JSON.parse json
      end
      def date
        data.first
      end
      def key
        data[1]
      end
      def body
        data[2]
      end
    end
  end
end

