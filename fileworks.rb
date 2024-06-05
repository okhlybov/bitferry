require 'digest'
require 'ostruct'
require 'pathname'
require 'seven_zip_ruby'


module Fileworks


#
class Remote < OpenStruct

  PROGRESS = ->(_) { print '.' }

  # -> Local
  def fetch(destination = nil, file: nil, progress: PROGRESS, force: false)
    require 'down'
    file = destination.nil? ? local : File.join(destination, local) if file.nil?
    if force || !verify(file)
      # Local file either non-existent or fails the checksum test - refetch needed
      Down.download(remote, destination: file, progress_proc: progress)
      raise "checksum verification failure" if !verify(file)
    end
    Local.new(file)
  end

  #
  def remote = eval(%/"#{url}"/)

  #
  def local = File.basename(remote)

  # NOTE relying on the insertion order stability to apply the strongest available hasher
  HASHERS = {
    sha384: Digest::SHA384,
    sha256: Digest::SHA256,
    sha2: Digest::SHA2,
    sha1: Digest::SHA1,
    md5: Digest::MD5,
  }

  #
  def verify(file)
    if File.exist?(file)
      HASHERS.each do |hasher, cls|
        hash = self[hasher]
        return cls.file(file) == hash unless hash.nil?
      end
      true # No hash sum specified - check by file existence only
    else
      false
    end
  end

end


#
class Local < Pathname

  EXTRACTORS = {
    /.7z$/ => ->(source, destination) {
      require 'seven_zip_ruby'
      SevenZipRuby::Reader.extract_all(source, destination)
    }
  }

  def extract(destination = nil)
    EXTRACTORS.each do |rx, code|
      if rx.match(to_s)
        code.(to_s, destination)
        return true
      end
    end
    false
  end

end



end


Fileworks::Remote.new(
  version: '3.2.3',
  release: '1',
  arch: 'x86',
  url: 'https://github.com/oneclick/rubyinstaller2/releases/download/RubyInstaller-#{version}-#{release}/rubyinstaller-#{version}-#{release}-#{arch}.7z',
  sha256: '406597dca85bf5a9962f887f3b41a7bf7bf0e875c80efc8cee48cab9e988f5fa'
).fetch.extract