require "rack-livetraffic/version"

module Rack
  module Livetraffic
    # Your code goes here...
    def topic
      'livetraffic'
    end

    def key(*args)
      [topic , args].flatten.join('.')
    end

    extend self
  end
  LiveTraffic = Livetraffic

  require "rack-livetraffic/middleware"
end
