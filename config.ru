require 'rack-livetraffic'
require 'yaml'
hash = YAML.load_file './config/livetraffic.yaml'

use Rack::LiveTraffic::Middleware , hash[:middleware]

def fact(n)
  if n <= 1
	1
  else
	n * fact(n-1)
  end
end

app = proc do |env|
  if rand() > 0.5
    env['rack.livetraffic_id'] = 'foobar' 
  end
  n = env['PATH_INFO'].split('/').last.to_i
  nbang = fact(n)
  [200, {'Content-Type' => 'text/plain'}, ["fact:#{n}:#{nbang}"]]
end

run app
