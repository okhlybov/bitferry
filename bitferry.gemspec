# Ensure we require the local version and not the one we might have installed already
require File.join([File.dirname(__FILE__), 'lib', 'bitferry.rb'])
Gem::Specification.new do |s|
  s.name = 'bitferry'
  s.version = Bitferry::VERSION
  s.author = 'Oleg A. Khlybov'
  s.email = 'fougas@mail.ru'
  s.homepage = 'https://github.com/okhlybov/bitferry'
  s.license = 'BSD-3-Clause'
  s.platform = Gem::Platform::RUBY
  s.required_ruby_version = '>= 3.0.0'
  s.summary = 'File synchronization/backup automation tool'
  s.files = Dir['bin/*', 'lib/**/*', 'README.md', 'CHANGES.md'] # `git ls-files`.split("\n")
  s.require_paths << 'lib'
  #s.extra_rdoc_files = ['README.rdoc','bitferry.rdoc']
  #s.rdoc_options << '--title' << 'bitferry' << '--main' << 'README.rdoc' << '-ri'
  s.bindir = 'bin'
  s.executables = ['bitferry', 'bitferryfx']
  s.add_development_dependency('rake', '~> 13.0')
  #s.add_development_dependency('rdoc', '~> 6.6')
  s.add_development_dependency('down', '~> 5.0')
  s.add_development_dependency('seven-zip', '~> 1.4')
  s.add_development_dependency('archive-zip', '~> 0.12')
  s.add_development_dependency('redcarpet', '~> 3.6')
  #s.add_development_dependency('commonmarker', '~> 1.0')
  s.add_runtime_dependency('fxruby','~> 1.6')
  s.add_runtime_dependency('neatjson','~> 0.10')
  s.add_runtime_dependency('clamp','~> 1.3')
end