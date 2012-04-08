
require 'json'
module Rack
  module LiveTraffic
    # An HTTP request digest report.
    #
    # The rack_id is duplicated such that applications not interested in this
    # report can easily filter out items before parsing the JSON.
    RequestReport = Struct.new(:rack_id, :json) do
      def initialize(*args,&blk)
        super
        @body = @token = nil
      end
        
      def body
        @body ||= JSON.parse json
      end
      def start
        body['t0.sec']
      end
      alias :date :start
      def stop
        body['t1.sec']
      end
      def start_usec
        body['t0.usec']
      end
      def stop_usec
        body['t1.usec']
      end
      #duration in ms
      def lifetime
        (stop * 1000) - (start * 1000) + (stop_usec / 1000) - (start_usec / 1000)
      end
      def user_agent
        body['user-agent']
      end
      def path
        body['path']
      end
      def host
        body['host']
      end
      def url
        body['uri']
      end
      def ip
        body['ip']
      end
      def cookie
        body['cookie']
      end

      #unique token
      # - an optional identifying cookie
      # - the (IP,user-agent) tuple (to better identify behind NATs)
      #
      # cached for efficiency reason (computing SHA1 is lame)
      def token
        unless @token
          @token = if cookie 
                     #XXX appends a string to further reduce collision risk if
                     # the cookie is itself a sha1
                     "cookie:#{cookie}" 
                   else
                     str = ip + user_agent
                     Digest::SHA1.hexdigest str
                   end
        end
        @token
      end
    end
  end
end

