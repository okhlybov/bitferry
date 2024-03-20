require 'rake/clean'
require 'rubygems'
require 'rubygems/package_task'
require 'rdoc/task'
Rake::RDocTask.new do |rd|
  rd.main = "README.rdoc"
  rd.rdoc_files.include("README.rdoc","lib/**/*.rb","bin/**/*")
  rd.title = 'File synchronization/backup automation tool'
end

spec = eval(File.read('bitferry.gemspec'))

Gem::PackageTask.new(spec) do |pkg|
end
task :default => :package

require 'down'
require 'digest'
require 'ostruct'

require File.join([File.dirname(__FILE__), 'lib', 'bitferry.rb'])

module Windows

  Release = 1

  Version = Bitferry::VERSION

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

    def extract(destination)
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

  Cache = 'windows/cache'

  Build = 'windows/build'

  Bitferry = 'windows/bitferry'

  Runtime = "#{Build}/bitferry/runtime"

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

  def self.start(cmd)
    if Gem::Platform.local.os == "linux"
      Rake.sh "env -i wine cmd /c #{cmd}"
    else
      Rake.sh cmd
    end
  end
  
end

require 'rake/clean'

CLEAN << Windows::Build
CLOBBER << Windows::Cache

namespace :windows do

  task :pristine do |t|
    rm_rf Windows::Build
    mkdir_p Windows::Build
  end

  namespace :ruby do
    task :extract => :pristine do
      Windows::Ruby.extract(Windows::Build)
    end
    task :normalize => :extract do
      mkdir_p Windows::Runtime
      File.rename Dir["#{Windows::Build}/rubyinstaller-*"].first, Windows::Runtime
    end
    task :ruby => :normalize do
      cd "#{Windows::Runtime}/bin" do
        Windows.start "gem install bitferry --version #{Windows::Version}"
      end
      cd Windows::Runtime do
        rm_rf Dir['include', 'share', 'packages', 'ridk_use', 'LICENSE*']
        rm_rf Dir['bin/ridk*', 'lib/*.a', 'lib/pkgconfig', 'lib/ruby/gems/*/cache/*', 'lib/ruby/gems/*/doc/*']
      end
    end
    task :ruby => :fxruby # Enable to include FXRuby in release
    task :fxruby => :normalize do
      cd "#{Windows::Runtime}/bin" do
        Windows.start 'gem install fxruby'
      end
      cd Dir["#{Windows::Runtime}/lib/ruby/gems/*/gems/fxruby-*"].first do
        rb = RbConfig::CONFIG['MAJOR'] + '.' + RbConfig::CONFIG['MINOR']
        Dir.children('.').delete_if { |x| /(lib|ports)$/.match?(x) }.each { |x| rm_rf x }
        Dir['lib/*'].delete_if { |x| /^lib\/(#{rb}|fox16)/.match?(x) }.each { |x| rm_rf x }
      end
    end
  end

  namespace :restic do
    task :extract => :pristine do
      Windows::Restic.extract(Windows::Build)
    end
  end

  namespace :rclone do
    task :extract => :pristine do
      Windows::Rclone.extract(Windows::Build)
    end
  end

  task :runtime => ['ruby:ruby', 'restic:extract', 'rclone:extract'] do
    site = Dir["#{Windows::Runtime}/lib/ruby/site_ruby/*"].first
    dir = "#{site}/bitferry"
    mkdir_p dir
    cp 'windows/windows.rb', dir
    bin = "#{Windows::Build}/bitferry/bin"
    mkdir_p bin
    cp 'windows/bitferry.cmd', bin
    sh "erb bitferry=#{Windows::Version} rclone=#{Windows::Rclone.version} restic=#{Windows::Restic.version} windows/README.txt.erb > README.txt"
    require 'commonmarker'
    File.write("#{Windows::Build}/bitferry/README.html", Commonmarker.to_html(File.read('README.md'), plugins: { syntax_highlighter: { theme: "InspiredGitHub" } }))
    mv Dir["#{Windows::Build}/restic*.exe"].first, "#{Windows::Runtime}/bin/restic.exe"
    mv Dir["#{Windows::Build}/rclone*/rclone.exe"].first, "#{Windows::Runtime}/bin"; rm_rf Dir["#{Windows::Build}/rclone*"]
  end

  task :zip => :runtime do
    cd Windows::Build do
      sh "zip -r -9 -o #{Windows::Bitferry}-#{Windows::Version}-win32-#{Windows::Release}.zip #{Windows::Bitferry}"
    end
  end

  task :installer => :runtime do
    sh "erb bitferry=#{Windows::Version} release=#{Windows::Release} windows/bitferry.iss.erb > bitferry.iss"
    cd 'windows' do Windows.start 'iss.cmd' end
  end

end
