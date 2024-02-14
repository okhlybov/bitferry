require 'down'
require 'digest'
require 'ostruct'

# Download from URL, verify and extract archive
class Source < OpenStruct

  def location = eval %/"#{url}"/

  def storage = Cache

  def destination = Build

  def fetch
    x = location
    FileUtils.mkdir_p(storage)
    file = File.join(storage, File.basename(x))
    unless File.exist?(file) && Digest::SHA256.file(file) == sha256
      puts "fetching #{x}"
      file_ = Down.download(x, progress_proc: ->(_) { print '.' })
      FileUtils.mv(file_, file)
      puts
      raise "checksum mismatch for #{x}" unless Digest::SHA256.file(file) == sha256
    end
    file
  end

  def extract
    file = fetch
    case file
    when /zip$/
      `unzip -o "#{file}" -d "#{destination}"`
    when /7z$/
      `7z x "#{file}" "-o#{destination}"`
    else
      raise "unsupported archive format for #{file}"
    end
  end

end

Build = 'build'

Cache = 'cache'

Ruby = Source.new(
  version: '3.2.3',
  release: '1',
  arch: 'x86',
  url: 'https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-#{version}-#{release}/rubyinstaller-#{version}-#{release}-#{arch}.7z',
  sha256: '406597dca85bf5a9962f887f3b41a7bf7bf0e875c80efc8cee48cab9e988f5fa'
)

Rclone = Source.new(
  version: '1.65.2',
  arch: 'windows-386',
  url: 'https://downloads.rclone.org/v#{version}/rclone-v#{version}-#{arch}.zip',
  sha256: '2261b96a6bd64788c498d0cd1e6a327f169a0092972dd3bbbb2ff2251ab78252'
)

Restic = Source.new(
  version: '0.16.4',
  arch: 'windows_386',
  url: 'https://github.com/restic/restic/releases/download/v#{version}/restic_#{version}_#{arch}.zip',
  sha256: '46d932ff5e5ca781fb01d313a56cf4087f27250fbdc0d7cb56fa958476bb8af8'
)

require 'rake/clean'

CLEAN << Build
CLOBBER << Cache

def start(cmd)
  if Gem::Platform.local.os == "linux"
    sh "env -i wine cmd /c #{cmd}"
  else
    sh cmd
  end
end

task :pristine do |t|
  rm_rf Build
  mkdir_p Build
end

namespace :ruby do
  task :extract => :pristine do
    Ruby.extract
  end
  task :normalize => :extract do
    cd Build do
      mv Dir['rubyinstaller-*'].first, 'ruby'
    end
  end
  task :configure => :normalize do
    cd "#{Build}/ruby/bin" do
      start 'gem install fxruby'
    end
  end
  task :ruby => :configure do
    cd "#{Build}/ruby" do
      rm_rf Dir['include', 'share', 'packages', 'ridk_use']
      rm_rf Dir['bin/ridk*', 'lib/*.a', 'lib/pkgconfig', 'lib/ruby/gems/*/cache/*', 'lib/ruby/gems/*/doc/*']
    end
  end
  task :fxruby => :ruby do
    cd Dir["#{Build}/ruby/lib/ruby/gems/*/gems/fxruby-*"].first do
      rb = RbConfig::CONFIG['MAJOR'] + '.' + RbConfig::CONFIG['MINOR']
      Dir.children('.').delete_if { |x| /(lib|ports)$/.match?(x) }.each { |x| rm_rf x }
      Dir['lib/*'].delete_if { |x| /^lib\/(#{rb}|fox16)/.match?(x) }.each { |x| rm_rf x }
    end
  end
end

namespace :restic do
  task :extract => :pristine do
    Restic.extract
  end
end

namespace :rclone do
  task :extract => :pristine do
    Rclone.extract
  end
end

task :default => 'ruby:fxruby'