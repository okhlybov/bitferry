require 'json'
require 'date'
require 'open3'
require 'base64'
require 'logger'
require 'openssl'
require 'pathname'
require 'neatjson'
require 'rbconfig'
require 'fileutils'
require 'shellwords'


module Bitferry


  VERSION = '0.0.7'


  module Logging
    def self.log
      unless @log
        @log = Logger.new($stderr)
        @log.level = Logger::WARN
        @log.progname = :bitferry
      end
      @log
    end
    def self.log=(log) @log = log end
    def log = Logging.log
  end


  include Logging
  extend  Logging


  def self.tag = format('%08x', 2**32*rand)


  def self.restore
    reset
    log.info('restoring volumes')
    result = true
    roots = (environment_mounts + system_mounts + [Dir.home]).uniq
    log.info("distilled volume search path: #{roots.join(', ')}")
    roots.each do |root|
      if File.exist?(File.join(root, Volume::STORAGE))
        log.info("trying to restore volume from #{root}")
        Volume.restore(root) rescue result = false
      end
    end
    if result
      log.info('volumes restored')
    else
      log.warn('volume restore failure(s) reported')
    end
    result
  end


  def self.commit
    log.info('committing changes')
    result = true
    modified = false
    Volume.registered.each do |volume|
      begin
        modified = true if volume.modified?
        volume.commit
      rescue IOError => e
         log.error(e.message)
         result = false
      end
    end
    if result
      log.info(modified ? 'changes committed' : 'commits skipped (no changes)')
    else
      log.warn('commit failure(s) reported')
    end
    result
  end


  def self.reset
    log.info('resetting state')
    Volume.reset
    Task.reset
  end


  def self.intact_tasks = Volume.intact.collect { |volume| volume.intact_tasks }.flatten.uniq

  def self.process(*tags, &block)
    log.info('processing tasks')
    tasks = intact_tasks
    if tags.empty?
      process = tasks
    else
      process = []
      tags.each do |tag|
        case (tasks = Task.match([tag], tasks)).size
          when 0 then log.warn("no tasks matching (partial) tag #{tag}")
          when 1 then process += tasks
          else
            tags = tasks.collect { |v| v.tag }.join(', ')
            raise ArgumentError, "multiple tasks matching (partial) tag #{tag}: #{tags}"
        end
      end
    end
    tasks = process.uniq
    total = tasks.size
    processed = 0
    failed = 0
    result = tasks.all? do |task|
      r = task.process
      processed += 1
      failed += 1 unless r
      yield(total, processed, failed) if block_given?
      r
    end
    result ? log.info('tasks processed') : log.warn('task process failure(s) reported')
    result
  end


  def self.endpoint(root)
    case root
      when /^:(\w+):(.*)/
        volumes = Volume.lookup($1)
        volume = case volumes.size
          when 0 then raise ArgumentError, "no intact volume matching (partial) tag #{$1}"
          when 1 then volumes.first
          else
            tags = volumes.collect { |v| v.tag }.join(', ')
            raise ArgumentError, "multiple intact volumes matching (partial) tag #{$1}: #{tags}"
        end
        Endpoint::Bitferry.new(volume, $2)
      when /^(?:local)?:(.*)/ then Endpoint::Local.new($1)
      when /^(\w{2,}):(.*)/ then Endpoint::Rclone.new($1, $2)
      else Volume.endpoint(root)
    end
  end


  @simulate = false
  def self.simulate? = @simulate
  def self.simulate=(mode) @simulate = mode end


  @verbosity = :default
  def self.verbosity = @verbosity
  def self.verbosity=(mode) @verbosity = mode end


  @ui = :cli
  def self.ui = @ui
  def self.ui=(ui) @ui = ui end


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
    extend Logging


    STORAGE      = '.bitferry'
    STORAGE_     = '.bitferry~'
    STORAGE_MASK = '.bitferry*'


    attr_reader :tag


    attr_reader :generation


    attr_reader :root


    attr_reader :vault


    def self.[](tag)
      @@registry.each_value { |volume| return volume if volume.tag == tag }
      nil
    end


    # Return list of registered volumes whose tags match at least one specified partial
    def self.lookup(*tags) = match(tags, registered)


    def self.match(tags, volumes)
      rxs = tags.collect { |x| Regexp.new(x) }
      volumes.filter do |volume|
        rxs.any? { |rx| !(rx =~ volume.tag).nil? }
      end
    end


    def self.new(root, **opts)
      volume = allocate
      volume.send(:create, root, **opts)
      register(volume)
    end


    def self.restore(root)
      begin
        volume = allocate
        volume.send(:restore, root)
        volume = register(volume)
        log.info("restored volume #{volume.tag} from #{root}")
        volume
      rescue => e
        log.error("failed to restore volume from #{root}")
        log.error(e.message) if $DEBUG
        raise
      end
    end


    def self.delete(*tags, wipe: false)
      process = []
      tags.each do |tag|
        case (volumes = Volume.lookup(tag)).size
          when 0 then log.warn("no volumes matching (partial) tag #{tag}")
          when 1 then process += volumes
          else
            tags = volumes.collect { |v| v.tag }.join(', ')
            raise ArgumentError, "multiple volumes matching (partial) tag #{tag}: #{tags}"
        end
      end
      process.each { |volume| volume.delete(wipe: wipe) }
    end


    def initialize(root, tag: Bitferry.tag, modified: DateTime.now, overwrite: false)
      @tag = tag
      @generation = 0
      @vault = {}
      @modified = modified
      @overwrite = overwrite
      @root = Pathname.new(root).realdirpath
    end


    def create(*args, **opts)
      initialize(*args, **opts)
      @state = :pristine
      @modified = true
    end


    def restore(root)
      hash = JSON.load_file(storage = Pathname(root).join(STORAGE), { symbolize_names: true })
      raise IOError, "bad volume storage #{storage}" unless hash.fetch(:bitferry) == "0"
      initialize(root, tag: hash.fetch(:volume), modified: DateTime.parse(hash.fetch(:modified)))
      hash.fetch(:tasks, []).each { |hash| Task::ROUTE.fetch(hash.fetch(:operation).intern).restore(hash) }
      @vault = hash.fetch(:vault, {}).transform_keys { |key| key.to_s }
      @state = :intact
      @modified = false
    end


    def storage  = @storage  ||= root.join(STORAGE)
    def storage_ = @storage_ ||= root.join(STORAGE_)


    def commit
      if modified?
        log.info("commit volume #{tag} (modified)")
        case @state
        when :pristine
          format
          store
        when :intact
          store
        when :removing
          remove
        else
          raise
        end
        committed
      else
        log.info("skipped committing volume #{tag} (unmodified)")
      end
    end


    def self.endpoint(root)
      path = Pathname.new(root).realdirpath
      intact.sort { |v1, v2| v2.root.to_s.size <=> v1.root.to_s.size }.each do |volume|
        begin
          stem = path.relative_path_from(volume.root).to_s #.chomp('/')
          case stem
            when '.' then return volume.endpoint
            when /^[^\.].*/ then return volume.endpoint(stem)
          end
        rescue ArgumentError
          # Catch different prefix error on Windows
        end
      end
      raise ArgumentError, "no intact volume encompasses path #{root}"
    end


    def endpoint(path = String.new) = Endpoint::Bitferry.new(self, path)


    def modified? = @modified || tasks.any? { |t| t.generation > generation }


    def intact? = @state != :removing


    def touch
      x = tasks.collect { |t| t.generation }.max
      @generation = x ? x + 1 : 0
      @modified = true
    end


    def delete(wipe: false)
      touch
      @wipe = wipe
      @state = :removing
      log.info("marked volume #{tag} for deletion")
    end


    def committed
      x = tasks.collect { |t| t.generation }.min
      @generation = x ? x : 0
      @modified = false
    end


    def store
      tasks.each(&:commit)
      hash = JSON.neat_generate(externalize, short: false, wrap: 200, afterColon: 1, afterComma: 1)
      if Bitferry.simulate?
        log.info("skipped volume #{tag} storage modification (simulation)")
      else
        begin
          File.write(storage_, hash)
          FileUtils.mv(storage_, storage)
          log.info("written volume #{tag} storage #{storage}")
        ensure
          FileUtils.rm_f(storage_)
        end
      end
      @state = :intact
    end


    def format
      raise IOError, "refuse to overwrite existing volume storage #{storage}" if !@overwrite && File.exist?(storage)
      if Bitferry.simulate?
        log.info("skipped storage formatting (simulation)")
      else
        FileUtils.mkdir_p(root)
        FileUtils.rm_f [storage, storage_]
        log.info("formatted volume #{tag} in #{root}")
      end
      @state = nil
    end


    def remove
      unless Bitferry.simulate?
        if @wipe
          FileUtils.rm_rf(Dir[File.join(root, '*'), File.join(root, '.*')])
          log.info("wiped entire volume directory #{root}")
        else
          FileUtils.rm_f [storage, storage_]
          log.info("deleted volume #{tag} storage files #{File.join(root, STORAGE_MASK)}")
        end
      end
      @@registry.delete(root)
      @state = nil
    end


    def externalize
      tasks = live_tasks
      v = vault.filter { |t| !Task[t].nil? && Task[t].live? } # Purge entries from non-existing (deleted) tasks
      {
        bitferry: "0",
        volume: tag,
        modified: (@modified = DateTime.now),
        tasks: tasks.empty? ? nil : tasks.collect(&:externalize),
        vault: v.empty? ? nil : v
      }.compact
    end


    def tasks = Task.registered.filter { |task| task.refers?(self) }


    def live_tasks = Task.live.filter { |task| task.refers?(self) }


    def intact_tasks = live_tasks.filter { |task| task.intact? }


    def self.reset = @@registry = {}


    def self.register(volume) = @@registry[volume.root] = volume


    def self.registered = @@registry.values


    def self.intact = registered.filter { |volume| volume.intact? }


  end


  def self.optional(option, route)
    case option
    when Array then option # Array is passed verbatim
    when '-' then nil # Disable adding any options with -
    when /^-/ then option.split(',') # Split comma-separated string into array --foo,bar --> [--foo, bar]
    else route.fetch(option.nil? ? nil : option.to_sym) # Obtain options from the profile database
    end
  end


  class Task


    include Logging
    extend  Logging


    attr_reader :tag


    attr_reader :generation


    attr_reader :modified


    attr_reader :include, :exclude


    def process_options = @process_options.nil? ? [] : @process_options # As a mandatory option it should never be nil


    def self.new(*args, **opts)
      task = allocate
      task.send(:create, *args, **opts)
      register(task)
    end


    def self.restore(hash)
      task = allocate
      task.send(:restore, hash)
      register(task)
    end


    def self.delete(*tags)
      process = []
      tags.each do |tag|
        case (tasks = Task.lookup(tag)).size
          when 0 then log.warn("no tasks matching (partial) tag #{tag}")
          when 1 then process += tasks
          else
            tags = tasks.collect { |v| v.tag }.join(', ')
            raise ArgumentError, "multiple tasks matching (partial) tag #{tag}: #{tags}"
        end
      end
      process.each { |task| task.delete }
    end


    def initialize(tag: Bitferry.tag, modified: DateTime.now, include: [], exclude: [])
      @tag = tag
      @generation = 0
      @include = include
      @exclude = exclude
      @modified = modified.is_a?(DateTime) ? modified : DateTime.parse(modified)
      # FIXME handle process_options at this level
    end


    def create(*args, **opts)
      initialize(*args, **opts)
      @state = :pristine
      touch
    end


    def restore(hash)
      @include = hash.fetch(:include, [])
      @exclude = hash.fetch(:exclude, [])
      @state = :intact
      log.info("restored task #{tag}")
    end


    # FIXME move to Endpoint#restore
    def restore_endpoint(x) = Endpoint::ROUTE.fetch(x.fetch(:endpoint).intern).restore(x)


    def externalize
      {
        task: tag,
        modified: modified,
        include: include.empty? ? nil : include,
        exclude: exclude.empty? ? nil : exclude
      }.compact
    end


    def live? = !@state.nil? && @state != :removing


    def touch = @modified = DateTime.now


    def delete
      touch
      @state = :removing
      log.info("marked task #{tag} for removal")
    end


    def commit
      case @state
      when :pristine then format
      when :removing then @state = nil
      end
    end


    def show_filters
      xs = []
      xs << 'include: ' + include.join(',') unless include.empty?
      xs << 'exclude: ' + exclude.join(',') unless exclude.empty?
      xs.join(' ').to_s
    end


    def self.[](tag) = @@registry[tag]


    # Return list of registered tasks whose tags match at least one of specified partial tags
    def self.lookup(*tags) = match(tags, registered)


    # Return list of specified tasks whose tags match at least one of specified partial tags
    def self.match(tags, tasks)
      rxs = tags.collect { |x| Regexp.new(x) }
      tasks.filter do |task|
        rxs.any? { |rx| !(rx =~ task.tag).nil? }
      end
    end


    def self.registered = @@registry.values


    def self.live = registered.filter { |task| task.live? }


    def self.reset = @@registry = {}


    def self.register(task)
      # Task with newer timestamp replaces already registered task, if any
      if (xtag = @@registry[task.tag]).nil?
        @@registry[task.tag] = task
      elsif xtag.modified < task.modified
        @@registry[task.tag] = task
      else
        xtag
      end
    end

    def self.intact = live.filter { |task| task.intact? }


    def self.stale = live.filter { |task| !task.intact? }


  end


  module Rclone


    include Logging
    extend  Logging


    def self.executable = @executable ||= (rclone = ENV['RCLONE']).nil? ? 'rclone' : rclone


    def self.exec(*args)
      cmd = [executable] + args
      log.debug(cmd.collect(&:shellescape).join(' '))
      stdout, status = Open3.capture2e(*cmd)
      unless status.success?
        msg = "rclone exit code #{status.exitstatus}"
        log.error(msg)
        raise RuntimeError, msg
      end
      stdout.strip
    end


    # https://github.com/rclone/rclone/blob/master/fs/config/obscure/obscure.go
    SECRET = "\x9c\x93\x5b\x48\x73\x0a\x55\x4d\x6b\xfd\x7c\x63\xc8\x86\xa9\x2b\xd3\x90\x19\x8e\xb8\x12\x8a\xfb\xf4\xde\x16\x2b\x8b\x95\xf6\x38"


    def self.obscure(plain)
      cipher = OpenSSL::Cipher.new('AES-256-CTR')
      cipher.encrypt
      cipher.key = SECRET
      Base64.urlsafe_encode64(cipher.random_iv + cipher.update(plain) + cipher.final, padding: false)
    end


    def self.reveal(token) = exec('reveal', '--', token)


    class Encryption


      PROCESS = {
        default: ['--crypt-filename-encoding', :base32, '--crypt-filename-encryption', :standard],
        extended: ['--crypt-filename-encoding', :base32768, '--crypt-filename-encryption', :standard]
      }
      PROCESS[nil] = PROCESS[:default]


      def process_options = @process_options.nil? ? [] : @process_options # As a mandatory option it should never be nil


      def initialize(token, process: nil)
        @process_options = Bitferry.optional(process, PROCESS)
        @token = token
      end


      def create(password, **opts) = initialize(Rclone.obscure(password), **opts)


      def restore(hash) = @process_options = hash[:rclone]


      def externalize = process_options.empty? ? {} : { rclone: process_options }


      def configure(task) = install_token(task)


      def process(task) = ENV['RCLONE_CRYPT_PASSWORD'] = obtain_token(task)


      def arguments(task) = process_options + ['--crypt-remote', encrypted(task).root.to_s]


      def install_token(task)
        x = decrypted(task)
        raise TypeError, 'unsupported unencrypted endpoint type' unless x.is_a?(Endpoint::Bitferry)
        Volume[x.volume_tag].vault[task.tag] = @token # Token is stored on the decrypted end only
      end


      def obtain_token(task) = Volume[decrypted(task).volume_tag].vault.fetch(task.tag)


      def self.new(*args, **opts)
        obj = allocate
        obj.send(:create, *args, **opts)
        obj
      end


      def self.restore(hash)
        obj = ROUTE.fetch(hash.fetch(:operation).intern).allocate
        obj.send(:restore, hash)
        obj
      end


    end


    class Encrypt < Encryption


      def encrypted(task) = task.destination


      def decrypted(task) = task.source


      def externalize = super.merge(operation: :encrypt)


      def show_operation = 'encrypt+'


      def arguments(task) = super + [decrypted(task).root.to_s, ':crypt:']


    end


    class Decrypt < Encryption


      def encrypted(task) = task.source


      def decrypted(task) = task.destination


      def externalize = super.merge(operation: :decrypt)


      def show_operation = 'decrypt+'


      def arguments(task) = super + [':crypt:', decrypted(task).root.to_s]


    end


    ROUTE = {
      encrypt: Encrypt,
      decrypt: Decrypt
    }


    class Task < Bitferry::Task


      attr_reader :source, :destination


      attr_reader :encryption


      attr_reader :token


      PROCESS = {
        default: ['--metadata']
      }
      PROCESS[nil] = PROCESS[:default]


      def initialize(source, destination, encryption: nil, process: nil, **opts)
        super(**opts)
        @process_options = Bitferry.optional(process, PROCESS)
        @source = source.is_a?(Endpoint) ? source : Bitferry.endpoint(source)
        @destination = destination.is_a?(Endpoint) ? destination : Bitferry.endpoint(destination)
        @encryption = encryption
      end


      def create(*args, process: nil, **opts)
        super(*args, process: process, **opts)
        encryption.configure(self) unless encryption.nil?
      end


      def show_status = "#{show_operation} #{source.show_status} #{show_direction} #{destination.show_status} #{show_filters}"


      def show_operation = encryption.nil? ? '' : encryption.show_operation


      def show_direction = '-->'


      def intact? = live? && source.intact? && destination.intact?


      def refers?(volume) = source.refers?(volume) || destination.refers?(volume)


      def touch
        @generation = [source.generation, destination.generation].max + 1
        super
      end


      def format = nil


      def common_options
        [
          '--config', Bitferry.windows? ? 'NUL' : '/dev/null',
          case Bitferry.verbosity
            when :verbose then '--verbose'
            when :quiet then '--quiet'
            else nil
          end,
          Bitferry.verbosity == :verbose && Bitferry.ui == :cli ? '--progress' : nil,
          Bitferry.simulate? ? '--dry-run' : nil,
        ].compact
      end


      def include_filters = include.collect { |x| ['--filter', "+ #{x}"]}.flatten


      def exclude_filters = ([Volume::STORAGE, Volume::STORAGE_] + exclude).collect { |x| ['--filter', "- #{x}"]}.flatten


      def process_arguments
        include_filters + exclude_filters + common_options + process_options + (
          encryption.nil? ? [source.root.to_s, destination.root.to_s] : encryption.arguments(self)
        )
      end


      def execute(*args)
        cmd = [Rclone.executable] + args
        cms = cmd.collect(&:shellescape).join(' ')
        $stdout.puts cms if Bitferry.verbosity == :verbose
        log.info(cms)
        oe, status = Open3.capture2e(*cmd)
        $stdout.puts oe
        raise RuntimeError, "rclone exit code #{status.exitstatus}" unless status.success?
        status.success?
      end


      def process
        log.info("processing task #{tag}")
        encryption.process(self) unless encryption.nil?
        execute(*process_arguments)
      end


      def externalize
        super.merge(
          source: source.externalize,
          destination: destination.externalize,
          encryption: encryption.nil? ? nil : encryption.externalize,
          rclone: process_options.empty? ? nil : process_options
        ).compact
      end


      def restore(hash)
        initialize(
          restore_endpoint(hash.fetch(:source)),
          restore_endpoint(hash.fetch(:destination)),
          tag: hash.fetch(:task),
          modified: hash.fetch(:modified, DateTime.now),
          process: hash[:rclone],
          encryption: hash[:encryption].nil? ? nil : Rclone::Encryption.restore(hash[:encryption])
        )
        super(hash)
      end


    end


    class Copy < Task


      def process_arguments = ['copy'] + super


      def externalize = super.merge(operation: :copy)


      def show_operation = super + 'copy'


    end


    class Update < Task


      def process_arguments = ['copy', '--update'] + super


      def externalize = super.merge(operation: :update)


      def show_operation = super + 'update'


    end


    class Synchronize < Task


      def process_arguments = ['sync'] + super


      def externalize = super.merge(operation: :synchronize)


      def show_operation = super + 'synchronize'


    end


    class Equalize < Task


      def process_arguments = ['bisync', '--resync'] + super


      def externalize = super.merge(operation: :equalize)


      def show_operation = super + 'equalize'


      def show_direction = '<->'


    end


  end


  module Restic


    include Logging
    extend  Logging


    def self.executable = @executable ||= (restic = ENV['RESTIC']).nil? ? 'restic' : restic


    def self.exec(*args)
      cmd = [executable] + args
      log.debug(cmd.collect(&:shellescape).join(' '))
      stdout, status = Open3.capture2(*cmd)
      unless status.success?
        msg = "restic exit code #{status.to_i}"
        log.error(msg)
        raise RuntimeError, msg
      end
      stdout.strip
    end


    class Task < Bitferry::Task


      attr_reader :directory, :repository


      def initialize(directory, repository, **opts)
        super(**opts)
        @directory = directory.is_a?(Endpoint) ? directory : Bitferry.endpoint(directory)
        @repository = repository.is_a?(Endpoint) ? repository : Bitferry.endpoint(repository)
      end


      def create(directory, repository, password, **opts)
        super(directory, repository, **opts)
        raise TypeError, 'unsupported unencrypted endpoint type' unless self.directory.is_a?(Endpoint::Bitferry)
        Volume[self.directory.volume_tag].vault[tag] = Rclone.obscure(@password = password) # Token is stored on the decrypted end only
      end


      def password = @password ||= Rclone.reveal(Volume[directory.volume_tag].vault.fetch(tag))


      def intact? = live? && directory.intact? && repository.intact?


      def refers?(volume) = directory.refers?(volume) || repository.refers?(volume)


      def touch
        @generation = [directory.generation, repository.generation].max + 1
        super
      end


      def format = nil


      def include_filters = include.collect { |x| ['--include', x]}.flatten


      def common_options
        [
          case Bitferry.verbosity
            when :verbose then '--verbose'
            when :quiet then '--quiet'
            else nil
          end,
          '-r', repository.root.to_s
        ].compact
      end


      def execute(*args, simulate: false, chdir: nil)
        cmd = [Restic.executable] + args
        ENV['RESTIC_PASSWORD'] = password
        ENV['RESTIC_PROGRESS_FPS'] = 1.to_s if Bitferry.verbosity == :verbose && Bitferry.ui == :gui
        cms = cmd.collect(&:shellescape).join(' ')
        $stdout.puts cms if Bitferry.verbosity == :verbose
        log.info(cms)
        if simulate
          log.info('(simulated)')
          true
        else
          wd = Dir.getwd unless chdir.nil?
          begin
            Dir.chdir(chdir) unless chdir.nil?
            oe, status = Open3.capture2e(*cmd)
            $stdout.puts oe
            raise RuntimeError, "restic exit code #{status.exitstatus}" unless status.success?
            status.success?
          ensure
            Dir.chdir(wd) unless chdir.nil?
          end
        end
      end


      def externalize
        super.merge(
          directory: directory.externalize,
          repository: repository.externalize,
        ).compact
      end


      def restore(hash)
        initialize(
          restore_endpoint(hash.fetch(:directory)),
          restore_endpoint(hash.fetch(:repository)),
          tag: hash.fetch(:task),
          modified: hash.fetch(:modified, DateTime.now)
        )
        super(hash)
      end


    end


    class Backup < Task


      PROCESS = {
        default: ['--no-cache']
      }
      PROCESS[nil] = PROCESS[:default]


      FORGET = {
        default: ['--prune', '--no-cache', '--keep-within-hourly', '24h', '--keep-within-daily', '7d', '--keep-within-weekly', '30d', '--keep-within-monthly', '1y', '--keep-within-yearly', '100y']
      }
      FORGET[nil] = nil # Skip processing retention policy by default


      CHECK = {
        default: ['--no-cache'],
        full: ['--no-cache', '--read-data']
      }
      CHECK[nil] = nil # Skip integrity checking by default


      attr_reader :forget_options
      attr_reader :check_options


      def create(*args, format: nil, process: nil, forget: nil, check: nil, **opts)
        super(*args, **opts)
        @format = format
        @process_options = Bitferry.optional(process, PROCESS)
        @forget_options = Bitferry.optional(forget, FORGET)
        @check_options = Bitferry.optional(check, CHECK)
      end


      def exclude_filters = ([Volume::STORAGE, Volume::STORAGE_] + exclude).collect { |x| ['--exclude', x]}.flatten


      def show_status = "#{show_operation} #{directory.show_status} #{show_direction} #{repository.show_status} #{show_filters}"


      def show_operation = 'encrypt+backup'


      def show_direction = '-->'


      alias :source :directory
      alias :destination :repository


      def process
        begin
          log.info("processing task #{tag}")
          execute('backup', '.', '--tag', "bitferry,#{tag}", *exclude_filters, *process_options, *common_options_simulate, chdir: directory.root)
          unless check_options.nil?
            log.info("checking repository in #{repository.root}")
            execute('check', *check_options, *common_options)
          end
          unless forget_options.nil?
            log.info("performing repository maintenance tasks in #{repository.root}")
            execute('forget', '--tag', "bitferry,#{tag}", *forget_options.collect(&:to_s), *common_options_simulate)
          end
          true
        rescue
          false
        end
      end


      def common_options_simulate = common_options + [Bitferry.simulate? ? '--dry-run' : nil].compact


      def externalize
        restic = {
          process: process_options,
          forget: forget_options,
          check: check_options
        }.compact
        super.merge({
          operation: :backup,
          restic: restic.empty? ? nil : restic
        }.compact)
      end


      def restore(hash)
        super
        opts = hash.fetch(:restic, {})
        @process_options = opts[:process]
        @forget_options = opts[:forget]
        @check_options = opts[:check]
      end


      def format
        if Bitferry.simulate?
          log.info('skipped repository initialization (simulation)')
        else
          log.info("initializing repository for task #{tag}")
          if @format == true
            log.debug("wiping repository in #{repository.root}")
            ['config', 'data', 'index', 'keys', 'locks', 'snapshots'].each { |x| FileUtils.rm_rf(File.join(repository.root.to_s, x)) }
          end
          if @format == false
            # TODO validate existing repo
            log.info("attached to existing repository for task #{tag} in #{repository.root}")
          else
            begin
              execute(*common_options, 'init')
              log.info("initialized repository for task #{tag} in #{repository.root}")
            rescue
              log.fatal("failed to initialize repository for task #{tag} in #{repository.root}")
              raise
            end
          end
        end
        @state = :intact
      end


    end


    class Restore < Task


      PROCESS = {
        default: ['--no-cache', '--sparse']
      }
      PROCESS[nil] = PROCESS[:default]


      def create(*args, process: nil, **opts)
        super(*args, **opts)
        @process_options = Bitferry.optional(process, PROCESS)
      end


      def exclude_filters = exclude.collect { |x| ['--exclude', x]}.flatten


      def show_status = "#{show_operation} #{repository.show_status} #{show_direction} #{directory.show_status} #{show_filters}"


      def show_operation = 'decrypt+restore'


      def show_direction = '-->'


      alias :destination :directory
      alias :source :repository

      
      def externalize
        restic = {
          process: process_options
        }.compact
        super.merge({
          operation: :restore,
          restic: restic.empty? ? nil : restic
        }.compact)
      end


      def restore(hash)
        super
        opts = hash.fetch(:rclone, {})
        @process_options = opts[:process]
      end


      def process
        log.info("processing task #{tag}")
        begin
          # FIXME restore specifically tagged latest snapshot
          execute('restore', 'latest', '--target', directory.root.to_s, *include_filters, *exclude_filters, *process_options, *common_options, simulate: Bitferry.simulate?)
          true
        rescue
          false
        end
      end


    end



  end


  Task::ROUTE = {
    copy: Rclone::Copy,
    update: Rclone::Update,
    synchronize: Rclone::Synchronize,
    equalize: Rclone::Equalize,
    backup: Restic::Backup,
    restore: Restic::Restore
  }


  class Endpoint


    def self.restore(hash)
      endpoint = allocate
      endpoint.send(:restore, hash)
      endpoint
    end


    class Local < Endpoint


      attr_reader :root


      def initialize(root) = @root = Pathname.new(root).realdirpath


      def restore(hash) = initialize(hash.fetch(:root))


      def externalize
        {
          endpoint: :local,
          root: root
        }
      end


      def show_status = root.to_s


      def intact? = true


      def refers?(volume) = false


      def generation = 0


    end


    class Rclone < Endpoint
      # TODO
    end


    class Bitferry < Endpoint


      attr_reader :volume_tag


      attr_reader :path


      def root = Volume[volume_tag].root.join(path)


      def initialize(volume, path)
        @volume_tag = volume.tag
        @path = Pathname.new(path)
        raise ArgumentError, "expected relative path but got #{self.path}" unless (/^[\.\/]/ =~ self.path.to_s).nil?
      end


      def restore(hash)
        @volume_tag = hash.fetch(:volume)
        @path = Pathname.new(hash.fetch(:path, ''))
      end


      def externalize
        {
          endpoint: :bitferry,
          volume: volume_tag,
          path: path.to_s.empty? ? nil : path
        }.compact
      end


      def show_status = intact? ? ":#{volume_tag}:#{path}" : ":{#{volume_tag}}:#{path}"


      def intact? = !Volume[volume_tag].nil?


      def refers?(volume) = volume.tag == volume_tag


      def generation
        v = Volume[volume_tag]
        v ? v.generation : 0
      end


    end


    ROUTE = {
      local: Local,
      rclone: Rclone,
      bitferry: Bitferry
    }


  end


  reset


end
