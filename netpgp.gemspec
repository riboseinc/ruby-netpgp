# frozen_string_literal: true

lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |s|
  s.name        = 'netpgp'
  s.version     = '0.0.1'
  s.licenses    = "MIT"
  s.summary     = 'An interface to libnetpgp.so'
  s.description = 'Uses ruby-ffi to support PGP/GnuPG functionality. Requires libnetpgp.so.'
  s.authors       = ['Ribose Inc.']
  s.email         = ['open.source@ribose.com']

  s.files       = Dir['lib/**/*']
  s.platform    = Gem::Platform::RUBY

  s.add_dependency 'ffi'
  s.add_development_dependency 'rspec', '3.5.0'
end

