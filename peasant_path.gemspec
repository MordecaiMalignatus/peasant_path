# frozen_string_literal: true

require_relative "lib/peasant_path/version"

Gem::Specification.new do |spec|
  spec.name = "peasant_path"
  spec.version = PeasantPath::VERSION
  spec.authors = ["MordecaiMalignatus"]
  spec.summary = "Download web fiction from RoyalRoad.com and convert to EPUB"
  spec.required_ruby_version = ">= 3.0"

  spec.files = Dir["lib/**/*.rb", "bin/*", "views/**/*", "config.ru"]
  spec.bindir = "bin"
  spec.executables = ["peasant_path"]
  spec.require_paths = ["lib"]

  spec.add_dependency "nokogiri", "~> 1.19"
  spec.add_dependency "httparty", "~> 0.24.0"
  spec.add_dependency "gepub", "~> 2.0"
  spec.add_dependency "thor", "~> 1.3"
  spec.add_dependency "sinatra", "~> 4.1"
  spec.add_dependency "puma", "~> 6.4"
  spec.add_dependency "rackup", "~> 2.2"

  spec.add_development_dependency "rspec", "~> 3.13"
  spec.add_development_dependency "pry", "~> 0.16.0"
  spec.add_development_dependency "rufo", "~> 0.18.2"
  spec.add_development_dependency "rack-test", "~> 2.1"
end
