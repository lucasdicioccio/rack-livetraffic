Rack LiveTraffic
================

A solution for the [Easter Dimelo contest](HTTP://contest.dimelo.com/2012/03/06/ruby-easter-egg-contest.html).

Requirements
------------
* ruby
* bundler
* rack
* 0MQ
* Redis (on default port)
* your front-ends should be synchronized with NTP 

Statistics
----------

Statistics that can be computed online are closely related to map-reduce
computations.  Hence, we do not need to persist HTTP requests for a long time.
we can persist intermediary computation instead. By aggregating the
intermediary computations, we get a final result.  As an example to find the
slowest request in a set of requests (i.e., the max of duration), we can
partition the
set in multiple subsets and proceed in two steps: 

1. compute the max on each subset (we call these results intermediary results) 
2. compute the max of intermediary results

Rack::LiveTraffic statistics partition the requests based on their timestamp in
one-second bin. Rack::LiveTraffic then computes statistics and persists
intermediary results.  When a user calls rack-top, Rack::LiveTraffic then
performs the second step.  With this approach, Rack::LiveTraffic does not store
every HTTP request and keeps the CPU/memory costs bounded.


Implementation details
----------------------
Bullet-list for the impatient:
* 0MQ for communication between modules
* Redis for storage and expiration of old data (i.e., keeps the cache-size small)
* uniquify NAT connection 
* thread-safe (no shared states in the middleware except a Queue, the worker
  handles that with a mutex)
 
### User identification

Rack::LiveTraffic can identify distinct users with the same IP (i.e., behind a NAT) provided that:
* they have a different user-agent
* they are logged on your application and uniquely identified by a cookie
  (which you have to configure in ./config/livetraffic.yaml at the key
middleware::cookie )

### Time Synchronization

Rack::LiveTraffic timestamps requests in the middleware. In order to avoid
re-implementing a time-synchronization mechanism in Ruby for something already
done by NTP with kernel support, we just require that the middleware uses NTP
as a time source.

Provided that you use NTP as a time source. Rack::LiveTraffic uses UNIX
timestamps with one-second granularity. Hence Rack::LiveTraffic handle the
cases where your middleware are in different time zones or cases where there is
more than one second delay between the middleware and the workers. 

The operation are the following:
1. middleware gets called on an incoming request
2. timestamps t0
3. calls the application higher in the stack
4. timestamps t1
5. computes t1 - t0 using the full granularity (i.e., tv_sec + tv_usec)
6. digest the request into interesting fields
7. publishes the digest and gives it the timestamp t0.tv_sec , regardless of the duration t1-t0



### Architecture

The architecture is the following:

    +------------+  +------------+
    | middleware |  | middleware | ...
    +------------+  +------------+
         |(zmq:push)     |  
         o----------o----o----------- ...
                    | (zmq:pull)
    +------------------------------------------------+
    |   re-publisher (rack-dispatch)                 |
    +------------------------------------------------+
                    | (zmq:publish)
                    |
            o-------o------------------------------o----------------------o
            |                                      |                      |
            | (zmq:subscribe)                      |                      |
    +---------------------------------+            |                      |
    | compute statistics (top-worker) |            |                      |
    +---------------------------------+            |                      |
            | (zmq:publish)                        |                      |
            |                                      |                      |
            | (zmq:subscribe)                      |                      |
    +----------------+                    +---------------+               |
    |  persist stats |                    | persist HTTP  |               |
    +----------------+                    +---------------+               |
                 |                            |                           |
         +------------------------------------------+                     |
         |                 Redis                    |                     |
         +------------------------------------------+                     |
                 |                            |                           |
           +------------------------------------------------------------------+ 
           +                   display statistics (rack-top)                  + 
           +------------------------------------------------------------------+ 
    
    
So basically:
* middlewares compute HTTP request digests and push the digests to a dispatcher
* the dispatcher then publishes to whoever is interested 
* a worker subscribes to reports digests and publishes statistics
* a worker persists intermediary statistics (one per second per rack-id)
* a worker also persists the HTTP request digests (I explain why it is useful next)
* a display then outputs JSON statistics, it can optionally use live requests or use the persisted statistics/requests

#### Why should we persist HTTP requests?

For efficiency reasons, the statistics worker computes intermediary statistics
periodically and not on each HTTP request. That is, when rack-top runs, the
last few seconds of intermediary statistics may not be available yet. To cope
with this issue, rack-top computes the missing statistics from the
HTTP digests cache.
Once intermediary statistics are in Redis, the HTTP digests are of little use.
Hence, I recommend to persist HTTP requests for a time slightly larger than the
statistics computation rate in the top-worker.

Default parameters compute intermediary statistics every 5 seconds, and persist
HTTP digest for 10 seconds.

### Overall cost computations

Back of the envelope/bottom of the Readme.md calculations:

#### variables

* r: number of rack-ids (depend on the app, say ~10)
* s: number of statistics (depend on the app, say 5 like in Dimelo contest)
* h: history size in seconds (300 for 5minutes)
* S: statistics refresh rate (5 secs.)
* H: HTTP history size in seconds (say 2*S = 10secs)
* R: request arrival rate (in req/s, say 1000)

#### memory-size
M = (r+1)*s*h  + R*H  = history of statistics times number of rack.id 
                        + HTTP requests in the recent history
                      = ~1500 + ~10000 items

Here you can play a bit on S (and H) such that you do not persist HTTP request
digests for too long. You can also set H to zero by not persisting HTTP request
digest at all. In that case, rack-top may report statistics outdated by S
seconds (which is small and should not matter too much).

#### message-rate

m = 3*R + (r+1)*s    = 1 push per HTTP request 
                      + 2subscribed per republished HTTP request
                      + statistics every seconds
                 = ~3000 + ~100 msgs/seq

It seems clear that the limiting factor is the overall number of request per
seconds. Hence, the re-publisher will have a lot of load. The good news is that
this piece is so simple that you can easily replace it with a C or Haskell
application in 50 lines of code.

#### take-away

A good leverage is to not persist HTTP request digests (which is optional), we
relax the memory size and the message-rate in the application. The drawback of
disabling HTTP request persistence is that rack-top may give 5-seconds old
statistics (which, IMHO, is not too bad).

Finally, one can also compute intermediary statistics directly in the
middleware, but this brings the risk of delaying your application response
time.  If you browse through the code of Rack::LiveTraffic you will find that
you can easily have one worker per rack-id or one worker per statistics. Hence
you can split the computation load over different machines with not too much
efforts (at the expense of more messages).

Usage
-----

### Simple usage -- demo

You can run the example, provided that 
* TCP ports 5555 to 5558 are free
* Redis runs on default port

In a shell: 

    foreman start

In another shell: 

    ab -n 100 HTTP://localhost:9292/

In yet another shell: 

    bundle exec ruby ./script/rack-top        #for all requests
    bundle exec ruby ./script/rack-top foobar #for requests with rack-livetraffic set to "foobar"

### Advanced usage

The rack-top script can take a second argument, which is the configuration file
to use.  Besides the configuration file, rack-top also has some marvelous
command line options:

* <pre>--no-redis-HTTP</pre>
  Do not reload HTTP requests from the Redis cache, i.e. the last few
  seconds may not be taken into account, using this option will reduce load on
  the script if you have a lot of requests per seconds.

* <pre>--no-redis-stats</pre>
  Do not read pre-computed stats from the Redis cache, i.e. will not take
  into account the full last 3minutes but only the very recent history, you
  should avoid using this option but it can be useful for debugging purpose.
  
* <pre>--loop</pre> 
  Do not exit the program, rack-top will periodically print up-to-date
  results on STDOUT.

Note that if you use these options you must use these options after explicitly giving the rack-livetraffic-id (which can be an empty string for none), and the path to the configuration file. For example:

    bundle exec ruby ./script/rack-top '' ./config/livetraffic.yaml --loop --no-redis-HTTP

In other words, you must pass the rack_id (optionally empty) and the config
path explicitly.


Author
------
* Lucas DiCioccio [page](HTTP://dicioccio.fr) [blog](HTTP://unchoke.me)
