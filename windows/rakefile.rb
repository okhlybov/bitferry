require 'down'
require 'digest'
require 'ostruct'

# Download from URL, verify and extract archive
class Source < OpenStruct

  def location = eval %/"#{url}"/

  def fetch
    dest = Cache
    x = location
    FileUtils.mkdir_p(dest)
    file = File.join(dest, File.basename(x))
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
    dest = Build
    file = fetch
    case file
    when /zip$/
      `unzip -o "#{file}" -d "#{dest}"`
    when /7z$/
      `7z x "#{file}" "-o#{dest}"`
    else
      raise "unsupported archive format for #{file}"
    end
  end

end

Build = 'build'
Cache = 'cache'

require 'rake/clean'

CLEAN << Build
CLOBBER << Cache

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

task :pristine do |t|
  rm_rf Build
  mkdir_p Build
end

task :extract => :pristine do |t|
  [Ruby, Rclone, Restic].each do |x|
    x.extract
  end
end

task :default => :extract