require 'json'
require 'date'
require 'logger'
require 'pathname'
require 'rbconfig'
require 'fileutils'


module Bitferry


  module Logging
    @@log = Logger.new($stderr)
    #@@log.level = Logger::Severity::WARN
    @@log.progname = :bitferry
  end


  include Logging


  VERSION = '0.0.1'


  def self.tag = format('%08x', 2**32*rand)


  def self.restore
    reset
    @@log.info('Volumes restore phase')
    result = true
    roots = (environment_mounts + system_mounts).uniq
    @@log.info("Distilled volume search path: #{roots}")
    roots.each do |root|
      if File.exist?(File.join(root, Volume::STORAGE))
        @@log.info("Trying to restore volume from #{root}")
        Volume.restore(root) rescue result = false
      end
    end
    @@log.info(result ? 'Volumes restore successful' : 'Volumes restore failure(s) reported')
    result
  end


  def self.commit
    @@log.info('Commit phase')
    result = true
    Volume.registered.each do |v|
      begin
        v.commit
      rescue IOError => e
         @@log.fatal(e.message)
         result = false
      end
    end
    @@log.info(result ? 'Commit successful' : 'Commit failure(s) reported')
    result
  end


  def self.reset
    @@log.info('Resetting to initial state')
    Volume.reset
    Task.reset
  end


  @simulate = false
  def self.simulate? = @simulate
  def self.simulate=(mode) @simulate = mode end


  # Return true if run in the real Windows environment (e.g. not in real *NIX or various emulation layers such as MSYS, Cygwin etc.)
  def self.windows?
    @windows ||= /^(mingw)/.match?(RbConfig::CONFIG['target_os']) # RubyInstaller's MRI, other MinGW-build MRI
  end

  # Return list of live user-provided mounts (mount points on *NIX and disk drives on Windows) which may contain Bitferry volumes
  # Look for the $BITFERRY_PATH environment variable
  def self.environment_mounts
    ENV['BITFERRY_PATH'].split(PATH_LIST_SEPARATOR).collect { |path| File.directory?(path) ? path : nil }.compact rescue []
  end


  # Specify OS-specific path name list separator (such as in the $PATH environment variable)
  PATH_LIST_SEPARATOR = windows? ? ';' : ':'


  # Match OS-specific system mount points (/dev /proc etc.) which normally should be omitted when scanning for Bitferry voulmes
  UNIX_SYSTEM_MOUNTS = %r!^/(dev|sys|proc|efi)!


  # Return list of live system-managed mounts (mount points on *NIX and disk drives on Windows) which may contain Bitferry volumes
  if RUBY_PLATFORM =~ /java/
    require 'java'
    def self.system_mounts
      java.nio.file.FileSystems.getDefault.getFileStores.collect {|x| /^(.*)\s+\(.*\)$/.match(x.to_s)[1]}
    end
  else
    case RbConfig::CONFIG['target_os']
    when 'linux'
      # Linux OS
      def self.system_mounts
        # Query /proc for currently mounted file systems
        IO.readlines('/proc/mounts').collect do |line|
          mount = line.split[1]
          UNIX_SYSTEM_MOUNTS.match?(mount) || !File.directory?(mount) ? nil : mount
        end.compact
      end
      # TODO handle Windows variants
    when /^mingw/ # RubyInstaller's MRI
    module Kernel32
      require 'fiddle'
      require 'fiddle/types'
      require 'fiddle/import'
      extend Fiddle::Importer
      dlload('kernel32')
      include Fiddle::Win32Types
      extern 'DWORD WINAPI GetLogicalDrives()'
    end  
      def self.system_mounts
        mounts = []
        mask = Kernel32.GetLogicalDrives
        ('A'..'Z').each do |x|
          mounts << "#{x}:/" if mask & 1 == 1
          mask >>= 1
        end
        mounts
      end
    else
      # Generic *NIX-like OS, including Cygwin & MSYS2
      def self.system_mounts
        # Use $(mount) system utility to obtain currently mounted file systems
        %x(mount).split("\n").collect do |line|
          mount = line.split[2]
          UNIX_SYSTEM_MOUNTS.match?(mount) || !File.directory?(mount) ? nil : mount
        end.compact
      end
    end
  end


  class Volume


    include Logging


    STORAGE  = '.bitferry'
    STORAGE_ = '.bitferry~'


    attr_reader :tag


    attr_reader :generation


    attr_reader :root


    @force_overwrite = false


    def self.force_overwrite? = @force_overwrite


    def self.force_overwrite=(mode) @force_overwrite = mode end


    def self.[](tag)
      @@registry.each_value { |v| return v if v.tag == tag }
      nil
    end


    def self.new(root)
      volume = allocate
      volume.send(:create, root)
      register(volume)
    end


    def self.restore(root)
      begin
        volume = allocate
        volume.send(:restore, root)
        volume = register(volume)
        @@log.info("Successfully restored volume #{volume.tag} from #{root}")
        volume
      rescue => e
        @@log.error("Failed to restore volume from #{root}: #{e.message}")
        raise
      end
    end


    private def initialize(root, tag: Bitferry.tag, timestamp: DateTime.now)
      @tag = tag
      @generation = 0
      @timestamp = timestamp
      @root = Pathname.new(root).realdirpath
    end


    private def create(*, **)
      initialize(*, **)
      @state = :pristine
      @modified = true
    end


    private def restore(root)
      json = JSON.load_file(storage = Pathname(root).join(STORAGE), { symbolize_names: true })
      raise IOError, "Wrong volume storage #{storage}" unless json.fetch(:bitferry) == "0"
      initialize(root, tag: json.fetch(:tag), timestamp: DateTime.parse(json.fetch(:timestamp)))
      json.fetch(:tasks).each { |json| Task::ROUTE[json.fetch(:task)].restore(json) }
      @state = :intact
      @modified = false
    end


    def storage  = @storage  ||= root.join(STORAGE)
    def storage_ = @storage_ ||= root.join(STORAGE_)


    def commit
      if modified?
        case @state
        when :pristine
          format
          commit_tasks
          store
          @state = :intact
        when :intact
          commit_tasks
          store
        end
        committed
      end
    end


    def endpoint(path)
      # TODO check
      Endpoint::Bitferry.new(self, path)
    end

    def modified? = @modified || tasks.any? { |t| t.generation > generation }


    def touch
      x = tasks.collect { |t| t.generation }.max
      @generation = x ? x + 1 : 0
      @modified = true
    end


    private def commit_tasks = tasks.each(&:commit)


    private def committed
      x = tasks.collect { |t| t.generation }.min
      @generation = x ? x : 0
      @modified = false
    end


    private def store
      json = JSON.pretty_generate(to_ext)
      unless Bitferry.simulate?
        begin
          File.write(storage_, json)
          FileUtils.mv(storage_, storage)
        ensure
          FileUtils.rm_f(storage_)
        end
      end
    end


    private def format
      raise IOError.new("Refuse to overwrite existing volume storage #{storage}") if !Volume.force_overwrite? && File.exist?(storage)
      unless Bitferry.simulate?
        FileUtils.mkdir_p(root) 
        FileUtils.rm_f [storage, storage_]
      end
    end


    def to_ext
      {
        bitferry: "0",
        tag: tag,
        timestamp: (@timestamp = DateTime.now),
        tasks: intact_tasks.collect(&:to_ext)
      }
    end


    def tasks = Task.registered.filter { |t| t.refers?(self) }


    def intact_tasks = tasks.filter { |t| t.intact? }


    def self.reset = @@registry = {}


    def self.register(volume) = @@registry[volume.root] = volume


    def self.registered = @@registry.values


  end


  class Task


    attr_reader :source, :destination


    attr_reader :tag


    attr_reader :generation


    def self.new(source, destination)
      task = allocate
      task.send(:create, source, destination)
      register(task)
    end


    def self.restore(json)
      task = allocate
      task.send(:restore, json)
      register(task)
    end


    private def initialize(source, destination, tag: Bitferry.tag, timestamp: DateTime.now)
      @tag = tag
      @generation = 0
      @timestamp = timestamp
      @source = source
      @destination = destination
    end


    private def create(*, **)
      initialize(*, **)
      @state = :pristine
      touch
    end


    private def restore(json)
      s = json.fetch(:source)
      d = json.fetch(:destination)
      initialize(
        Endpoint::ROUTE[s.fetch(:endpoint)].restore(s),
        Endpoint::ROUTE[d.fetch(:endpoint)].restore(d),
        tag: json.fetch(:tag),
        timestamp: json.fetch(:timestamp)
      )
      @state = :intact
    end


    def to_ext
      {
        tag: tag,
        source: source.to_ext,
        destination: destination.to_ext,
        timestamp: (@timestamp = DateTime.now)
      }
    end


    def intact? = source.intact? && destination.intact?


    def refers?(volume) = source.refers?(volume) || destination.refers?(volume)


    def touch = @generation = [source.generation, destination.generation].max + 1


    def self.[](tag) = @@registry[tag]


    def self.registered = @@registry.values


    def self.reset = @@registry = {}


    def self.register(task) = @@registry[task.tag] = task


  end


  module Rclone
  end
  

  class Rclone::Copy < Task

    def to_ext = super.merge(task: :copy)

    def self.restore(hash)
      TODO
    end

    def commit
      # TODO
    end
  end


  class Rclone::Update < Task

    def to_ext = super.merge(task: :update)

    def self.restore(hash)
      TODO
    end

    def commit
      # TODO
    end
  end


  Task::ROUTE = { 'copy' => Rclone::Copy, 'update' => Rclone::Update }


  class Endpoint


    def self.restore(json)
      endpoint = allocate
      endpoint.send(:restore, json)
      endpoint
    end


  end


  class Endpoint::Local < Endpoint


    attr_reader :root


    private def initialize(root) = @root = Pathname.new(root)


    private def restore(json) = initialize(json.fetch(:root))


    def to_ext
      {
        endpoint: :local,
        root: root
      }
    end


    def intact? = true


    def refers?(volume) = false
      

    def generation = 0


  end


  class Endpoint::Bitferry < Endpoint


    attr_reader :volume_tag


    attr_reader :path


    private def initialize(volume, path)
      @volume_tag = volume.tag
      @path = Pathname.new(path) # TODO ensure relative
    end


    private def restore(json)
      @volume_tag = json.fetch(:volume)
      @path = Pathname.new(json.fetch(:path))
    end


    def to_ext
      {
        endpoint: :bitferry,
        volume: volume_tag,
        path: path
      }
    end


    def intact? = !Volume[volume_tag].nil?


    def refers?(volume) = volume.tag == volume_tag


    def generation
      v = Volume[volume_tag]
      v ? v.generation : 0
    end


    Endpoint::ROUTE = { 'local' => Endpoint::Local, 'bitferry' => Endpoint::Bitferry }

  end


  reset


end