
require 'rack-livetraffic/publisher'
require 'json'
require 'rack'
require 'thread'
require 'digest/sha1'

module Rack
  module LiveTraffic

    # This Middleware compute online digest of requests and publish them
    #
    # One goal is to be as lightweight as possible to avoid delaying HTTP
    # requests. Hence this middleware does not compute stats but merely
    # publish digests.
    #
    # This Middleware uses Thread and Queue.
    # One and only one thread is dedicated to publishing results, hence if you
    # don't use the stock publisher, it doesn't have to be thread safe as long
    # as it doesn't block the full runtime :).
    # Other (optionally multiple) Rack threads publish in the Queue, which
    # takes almost no time.
    #
    # This Middleware is NOT meant to work for async rack, just for Dimelo
    # contest :). Although it should not be hard to modify to run with async
    # rack applications.
    # In short:
    # * return -1 will not compute the actual query completion time and the
    # digest will measure the time to return -1
    # * throw :async will short-circuit the stack altogether and the digest
    # won't be published
    class Middleware
      attr_reader :pub, :cookie_name
      # initializes the middleware, the first argument is the Rack app
      # the second argument is a config with optional keys:
      # - :publisher => a publisher that respond to :publish(*args)
      # - :cookie    => the name of a cookie uniquely identifying your user;
      # for obvious security reasons the cookie will be SHA1-digested before
      # being published, if you don't want this behaviour monkey-patch this
      # library
      def initialize(app,cfg={})
        @app          = app
        push_cfg      = cfg[:push] || 'tcp://localhost:5555'
        @pub          = Publisher.new('middleware', push_cfg, :push)
        @cookie_name  = cfg[:cookie]    || ''
        @queue        = Queue.new
        publish_thread
      end

      # Rack application's #call
      def call(env)
        t0 = Time.now
        ret = @app.call env
        t1 = Time.now
        record env, ret, t0, t1
        ret
      end

      private

      # infinite loop publishing requests
      def publish_thread
        Thread.new do
          loop { publish_next }
        end
      end

      # dequeue digests'queue and publish the digest
      # blocking
      def publish_next
        args = @queue.pop
        pub.publish(*args)
      end

      # Formats a digest for a completed request.
      def format(env,ret,t0,t1)
        { 't0.sec'=> t0.tv_sec, 
          't0.usec'=> t0.tv_usec,
          't1.sec'=> t1.tv_sec, 
          't1.usec'=> t1.tv_usec,
          'host'=> env['SERVER_NAME'],
          'path'=> env['PATH_INFO'],
          'uri' => env['REQUEST_URI'],
          'ip'=> env['REMOTE_ADDR'],
          'user-agent' => env['HTTP_USER_AGENT'],
          'rack-id'=> key(env),
          'cookie' => cookie(env)
        }.to_json
      end

      # handy way to get the cookie uniquely identifying a user
      # note that for security reasons (who knows who will sniff your traffic?)
      # the cookie will be SHA1-digested
      def cookie(env)
        str = Rack::Request.new(env).cookies[cookie_name]
        Digest::SHA1.hexdigest str if str
      end

      # handy way to get the id for this app
      def key(env)
        env['rack.livetraffic_id'] || ''
      end

      # enqueue a digest for an HTTP request
      def record(env, ret, t0, t1)
        json  = format(env,ret,t0,t1)
        @queue << [key(env), json]
      end
    end
  end
end
