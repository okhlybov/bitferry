# Ensure we require the local version and not one we might have installed already
require File.join([File.dirname(__FILE__), 'lib', 'bitferry.rb'])
spec = Gem::Specification.new do |s|
  s.name = 'bitferry'
  s.version = Bitferry::VERSION
  s.author = 'Oleg A. Khlybov'
  s.email = 'fougas@mail.ru'
  s.homepage = 'https://github.com/okhlybov/bitferry'
  s.license = 'BSD-3-Clause'
  s.platform = Gem::Platform::RUBY
  s.summary = 'File synchronization/backup automation tool'
  s.files = Dir['bin/*', 'lib/**', 'README.md'] #`git ls-files`.split("\n")
  s.require_paths << 'lib'
  s.extra_rdoc_files = ['README.rdoc','bitferry.rdoc']
  s.rdoc_options << '--title' << 'bitferry' << '--main' << 'README.rdoc' << '-ri'
  s.bindir = 'bin'
  s.executables << 'bitferry'
  s.add_development_dependency('rake')
  s.add_development_dependency('rdoc')
  s.add_development_dependency('down', '~> 5.0')
  s.add_runtime_dependency('clamp','~> 1.3.2')
end