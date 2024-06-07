# Gems: down seven-zip archive-zip


require 'digest'
require 'ostruct'
require 'pathname'


module Fileworks


#
class Remote < OpenStruct

  PROGRESS = ->(_) { print '.' }

  # -> Local
  def fetch(destination = '.', file: nil, progress: PROGRESS, force: false)
    require 'down'
    file = File.join(destination.to_s, local)
    if force || !verify(file)
      # Local file either non-existent or fails the checksum test - refetch needed
      Down.download(remote, destination: file, progress_proc: progress)
      raise 'checksum verification failure' if !verify(file)
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
      File.open(source, 'rb') { |stream| SevenZipRuby::Reader.extract_all(stream, destination) }
    },
    /.zip$/ => ->(source, destination) {
      require 'archive/zip'
      Archive::Zip.extract(source, destination)
    },
  }

  #
  def extract(destination = '.')
    EXTRACTORS.each do |rx, code|
      if rx.match(to_s)
        code.(to_s, destination.to_s)
        return
      end
    end
    raise 'unsupported archive type'
  end

end



end
