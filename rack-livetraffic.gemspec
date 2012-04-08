# -*- encoding: utf-8 -*-
$:.push File.expand_path("../lib", __FILE__)
require "rack-livetraffic/version"

Gem::Specification.new do |s|
  s.name        = "rack-livetraffic"
  s.version     = Rack::Livetraffic::VERSION
  s.authors     = ["lucas dicioccio"]
  s.email       = ["lucas@dicioccio.fr"]
  s.homepage    = ""
  s.summary     = %q{Live usage and performance statistics for your Ruby web apps}
  s.description = %q{Rack::Livetraffic is a Rack middleware and a set of workers to efficiently compute statistics for your web applications}

  s.rubyforge_project = "rack-livetraffic"

  s.files         = `git ls-files`.split("\n")
  s.test_files    = `git ls-files -- {test,spec,features}/*`.split("\n")
  s.executables   = `git ls-files -- bin/*`.split("\n").map{ |f| File.basename(f) }
  s.require_paths = ["lib"]
end
