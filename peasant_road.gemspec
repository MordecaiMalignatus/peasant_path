# frozen_string_literal: true

require_relative "lib/peasant_road/version"

Gem::Specification.new do |spec|
  spec.name = "peasant_road"
  spec.version = PeasantRoad::VERSION
  spec.authors = ["MordecaiMalignatus"]
  spec.summary = "Download web fiction from RoyalRoad.com and convert to EPUB"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb", "bin/*"]
  spec.bindir = "bin"
  spec.executables = ["peasant_road"]
  spec.require_paths = ["lib"]

  spec.add_dependency "nokogiri", "~> 1.19"
  spec.add_dependency "httparty", "~> 0.24.0"
  spec.add_dependency "gepub", "~> 2.0"
  spec.add_dependency "thor", "~> 1.3"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "pry", "~> 0.16.0"
  spec.add_development_dependency "rufo", "~> 0.18.2"
end
