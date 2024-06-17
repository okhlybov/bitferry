require_relative 'fileworks'


require 'rubygems'
require 'rubygems/package_task'


stage = directory('stage').to_s
build = directory(File.join(stage, 'build')).to_s
cache = directory('cache').to_s
bin = directory(File.join(build, 'bin')).to_s
sysroot = Gem::Platform.local.os == 'linux' ? `winepath -w "#{Dir.pwd}"` : Dir.pwd


require 'rake/clean'


CLEAN.concat [ stage, build, 'pkg' ]
CLOBBER.concat [ cache ]


def shell(cmd) = Gem::Platform.local.os == 'linux' ? sh("wine cmd /c #{cmd}") : sh(cmd)


namespace :windows do


  version = '0.0.7'
  release = 1


  ruby = Fileworks::Remote.new(
    version: '3.2.3',
    release: '1',
    arch: 'x86',
    url: 'https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-#{version}-#{release}/rubyinstaller-#{version}-#{release}-#{arch}.7z',
    sha256: '406597dca85bf5a9962f887f3b41a7bf7bf0e875c80efc8cee48cab9e988f5fa'
  )


  rclone = Fileworks::Remote.new(
    version: '1.66.0',
    arch: 'windows-386',
    url: 'https://downloads.rclone.org/v#{version}/rclone-v#{version}-#{arch}.zip',
    sha256: 'ca647f69c6bf2e831902a8bd9c5f4d16f7014314d5eeb94bd3a5389a92806de8'
  )


  restic = Fileworks::Remote.new(
    version: '0.16.4',
    arch: 'windows_386',
    url: 'https://github.com/restic/restic/releases/download/v#{version}/restic_#{version}_#{arch}.zip',
    sha256: '46d932ff5e5ca781fb01d313a56cf4087f27250fbdc0d7cb56fa958476bb8af8'
  )


  runtime = directory(File.join(build, 'runtime')).to_s
  runtime_bin = directory(File.join(runtime, 'bin')).to_s


  namespace :ruby do


    task :extract => [build, cache] do
      ruby.fetch(cache).extract(build)
    end


    task :runtime => :extract do
      rm_rf(runtime)
      mv Dir[File.join(build, 'rubyinstaller*')].first, runtime
    end


    task :normalize => [:runtime, :bitferry, :fxruby] do
      cd runtime do
        rm_rf Dir['include', 'share', 'packages', 'ridk_use', 'LICENSE*']
        rm_rf Dir['bin/ridk*', 'lib/*.a', 'lib/pkgconfig', 'lib/ruby/gems/*/cache/*', 'lib/ruby/gems/*/doc/*']
      end
    end


    task :bitferry => [:runtime, bin] do
      cd runtime_bin do
        shell "./gem install bitferry -N --version #{version}"
      end
      cp ['windows/bitferry.cmd', 'windows/bitferryfx.cmd'], bin
      wsite = File.join(Dir[File.join(runtime, 'lib/ruby/site_ruby/*')].first, 'bitferry')
      mkdir wsite
      cp 'windows/windows.rb', wsite
  end


    task :fxruby => [:runtime, :bitferry] do
      cd Dir[File.join(runtime, 'lib/ruby/gems/*/gems/fxruby-*')].first do
        rb = RbConfig::CONFIG['MAJOR'] + '.' + RbConfig::CONFIG['MINOR']
        Dir.children('.').delete_if { |x| /(lib|ports)$/.match?(x) }.each { |x| rm_rf x }
        Dir['lib/*'].delete_if { |x| /^lib\/(#{rb}|fox16)/.match?(x) }.each { |x| rm_rf x }
      end
    end


  end


  namespace :rclone do


    task :extract => [stage, cache] do
      rm_rf Dir[File.join(stage, 'rclone-*')]
      rclone.fetch(cache).extract(stage)
    end


    exe = File.join(runtime_bin, 'rclone.exe')


    file exe => [:extract, 'ruby:runtime'] do |t|
      cp Dir[File.join(stage, 'rclone-*', 'rclone.exe')].first, t.name
    end


    task :runtime => exe


  end


  namespace :restic do


    task :extract => [stage, cache] do
      rm_rf Dir[File.join(stage, 'restic-*')]
      restic.fetch(cache).extract(stage)
    end


    exe = File.join(runtime_bin, 'restic.exe')


    file exe => [:extract] do |t|
      cp Dir[File.join(stage, 'restic_*.exe')].first, t.name
    end


    task :runtime => exe


  end


  task :runtime => ['ruby:normalize', 'rclone:runtime', 'restic:runtime']


  task :installer => :runtime do
    require 'erb'
    File.open(File.join(stage, 'bitferry.iss'), 'wt') do |file|
      bitferry=version
      release=release
      file << ERB.new(File.read('windows/bitferry.iss.erb')).result(binding)
    end
    File.open(File.join(stage, 'README.txt'), 'wt') do |file|
      bitferry=version
      rclone = rclone.version
      restic = restic.version
      file << ERB.new(File.read('windows/README.txt.erb')).result(binding)
    end
    require 'redcarpet'
    File.open(File.join(build, 'README.html'), 'wt') do |file|
      file << Redcarpet::Markdown.new(Redcarpet::Render::HTML.new(hard_wrap: true), fenced_code_blocks: true, disable_indented_code_blocks: true).render(File.read('README.md'))
    end
    cp ['LICENSE', 'windows/path.iss', 'windows/iscc.cmd'], stage
    cd stage do
      require 'shellwords'
      shell "./iscc /Qp /O#{Shellwords.escape(sysroot)} bitferry.iss"
    end
  end


end
