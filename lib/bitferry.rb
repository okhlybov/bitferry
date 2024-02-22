require 'json'
require 'date'
require 'open3'
require 'logger'
require 'pathname'
require 'rbconfig'
require 'fileutils'
require 'shellwords'


module Bitferry


  VERSION = '0.0.1'


  module Logging
    def self.log
      unless @log
        @log = Logger.new($stderr)
        @log.level = Logger::WARN
        @log.progname = :bitferry
      end
      @log
    end
    def log = Logging.log
  end


  include Logging
  extend  Logging


  def self.tag = format('%08x', 2**32*rand)


  def self.restore
    reset
    log.info('restoring volumes')
    result = true
    roots = (environment_mounts + system_mounts).uniq
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


  def self.process
    log.info('processing tasks')
    result = Volume.intact.collect { |volume| volume.intact_tasks }.flatten.uniq.all? { |task| task.process }
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
    def self.lookup(*parts)
      rxs = parts.collect { |x| Regexp.new(x) }
      registered.filter do |volume|
        rxs.any? { |rx| !(rx =~ volume.tag).nil? }
      end
    end


    def self.new(root, **)
      volume = allocate
      volume.send(:create, root, **)
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


    def create(*, **)
      initialize(*, **)
      @state = :pristine
      @modified = true
    end


    def restore(root)
      hash = JSON.load_file(storage = Pathname(root).join(STORAGE), { symbolize_names: true })
      raise IOError, "bad volume storage #{storage}" unless hash.fetch(:bitferry) == "0"
      initialize(root, tag: hash.fetch(:tag), modified: DateTime.parse(hash.fetch(:modified)))
      hash.fetch(:tasks, []).each { |hash| Task::ROUTE.fetch(hash.fetch(:operation)).restore(hash) }
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
      # FIXME select innermost or outermost volume in case of nested volumes?
      intact.sort { |v1, v2| v2.root.size <=> v1.root.size }.each do |volume|
        begin
          # FIXME chop trailing slashes
          stem = path.relative_path_from(volume.root)
          case stem.to_s
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
      hash = JSON.pretty_generate(externalize)
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
        tag: tag,
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


  class Task


    include Logging
    extend  Logging
  

    attr_reader :tag


    attr_reader :generation


    attr_reader :modified


    def self.new(*, **)
      task = allocate
      task.send(:create, *, **)
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


    def initialize(tag: Bitferry.tag, modified: DateTime.now)
      @tag = tag
      @generation = 0
      @modified = modified
    end


    def create(*, **)
      initialize(*, **)
      @state = :pristine
      touch
    end


    def restore(hash)
      @state = :intact
      log.info("restored task #{tag}")
    end


    # FIXME move to Endpoint#restore
    def restore_endpoint(x) = Endpoint::ROUTE.fetch(x.fetch(:endpoint)).restore(x)


    def externalize
      {
        tag: tag,
        modified: @modified
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


    def self.[](tag) = @@registry[tag]


    # Return list of registered tasks whose tags match at least one of specified partial tags
    def self.lookup(*tags)
      rxs = tags.collect { |x| Regexp.new(x) }
      registered.filter do |task|
        rxs.any? { |rx| !(rx =~ task.tag).nil? }
      end
    end

    def self.registered = @@registry.values


    def self.live = registered.filter { |task| task.live? }


    def self.reset = @@registry = {}


    def self.register(task) = @@registry[task.tag] = task # TODO settle on task with the latest timestamp


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
      stdout, status = Open3.capture2(*cmd)
      unless status.success?
        msg = "rclone exit code #{status.to_i}"
        log.error(msg)
        raise RuntimeError, msg
      end
      stdout.strip
    end


    def self.obscure(plain) = exec('obscure', plain)


    def self.reveal(token) = exec('reveal', token)


  end


  class Rclone::Encryption


    NAME_ENCODER = { nil => nil, false => nil, base32: :base32, base64: :base64, base32768: :base32768 }


    NAME_TRANSFORMER = { nil => nil, false => :off, encrypter: :standard, obfuscator: :obfuscate }


    def options
      @options ||= [
        NAME_ENCODER.fetch(@name_encoder).nil? ? nil : ['--crypt-filename-encoding', NAME_ENCODER[@name_encoder]],
        NAME_TRANSFORMER.fetch(@name_transformer).nil? ? nil : ['--crypt-filename-encryption', NAME_TRANSFORMER[@name_transformer]]
      ].compact.flatten
    end


    def initialize(token, name_encoder: :base32, name_transformer: :encrypter)
      raise("bad file/directory name encoder #{name_encoder}") unless NAME_ENCODER.keys.include?(@name_encoder = name_encoder)
      raise("bad file/directory name transformer #{name_transformer}") unless NAME_TRANSFORMER.keys.include?(@name_transformer = name_transformer)
      @token = token
    end


    def create(password, **) = initialize(Rclone.obscure(password), **)


    def restore(hash) = @options = hash.fetch(:rclone, [])


    def externalize = options.empty? ? {} : { rclone: options }


    def configure(task) = install_token(task)


    def process(task) = ENV['RCLONE_CRYPT_PASSWORD'] = obtain_token(task)


    def arguments(task) = options + ['--crypt-remote', encrypted(task).root.to_s]


    def install_token(task)
      x = decrypted(task)
      raise TypeError, 'unsupported unencrypted endpoint type' unless x.is_a?(Endpoint::Bitferry)
      Volume[x.volume_tag].vault[task.tag] = @token # Token is stored on the decrypted end only
    end


    def obtain_token(task) = Volume[decrypted(task).volume_tag].vault.fetch(task.tag)


    def self.new(*, **)
      obj = allocate
      obj.send(:create, *, **)
      obj
    end


    def self.restore(hash)
      obj = ROUTE.fetch(hash.fetch(:operation).intern).allocate
      obj.send(:restore, hash)
      obj
    end


  end


  class Rclone::Encrypt < Rclone::Encryption


    def encrypted(task) = task.destination


    def decrypted(task) = task.source


    def externalize = super.merge(operation: :encrypt)


    def show_operation = 'encrypt+'


    def arguments(task) = super + [decrypted(task).root.to_s, ':crypt:']


  end


  class Rclone::Decrypt < Rclone::Encryption


    def encrypted(task) = task.source


    def decrypted(task) = task.destination


    def externalize = super.merge(operation: :decrypt)


    def show_operation = 'decrypt+'


    def arguments(task) = super + [':crypt:', decrypted(task).root.to_s]

  end


  Rclone::Encryption::ROUTE = { encrypt: Rclone::Encrypt, decrypt: Rclone::Decrypt }


  class Rclone::Task < Task


    attr_reader :source, :destination


    attr_reader :encryption


    attr_reader :token


    attr_reader :process_options


    PROCESS = {
      'default' => ['--preserve-metadata']
    }


    def initialize(source, destination, encryption: nil, process: nil, **opts)
      super(**opts)
      @process_options = process.nil? ? [] : process
      @source = source.is_a?(Endpoint) ? source : Bitferry.endpoint(source)
      @destination = destination.is_a?(Endpoint) ? destination : Bitferry.endpoint(destination)
      @encryption = encryption
    end


    def create(*, process: nil, **opts)
      super(*, process: process, **opts)
      encryption.configure(self) unless encryption.nil?
    end


    def show_status = "#{show_operation} #{source.show_status} #{show_direction} #{destination.show_status}"


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
        Bitferry.verbosity == :verbose ? '--progress' : nil,
        Bitferry.simulate? ? '--dry-run' : nil,
      ].compact
    end


    def process_arguments
      ['--filter', "- #{Volume::STORAGE}", '--filter', "- #{Volume::STORAGE_}"] + common_options + process_options + (
        encryption.nil? ? [source.root.to_s, destination.root.to_s] : encryption.arguments(self)
      )
    end


    def execute(*args)
      cmd = [Rclone.executable] + args
      cms = cmd.collect(&:shellescape).join(' ')
      puts cms if Bitferry.verbosity == :verbose
      log.info(cms)
      status = Open3.pipeline(cmd).first
      raise "rclone exit code #{status.exitstatus}" unless status.success?
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
        tag: hash.fetch(:tag),
        modified: hash.fetch(:modified, DateTime.now),
        process: hash.fetch(:rclone, []),
        encryption: hash[:encryption].nil? ? nil : Rclone::Encryption.restore(hash[:encryption])
      )
      super(hash)
    end


  end


  class Rclone::Copy < Rclone::Task


    def process_arguments = ['copy'] + super


    def externalize = super.merge(operation: :copy)


    def show_operation = super + 'copy'


  end


  class Rclone::Update < Rclone::Task


    def process_arguments = ['copy', '--update'] + super


    def externalize = super.merge(operation: :update)


    def show_operation = super + 'update'


  end


  class Rclone::Synchronize < Rclone::Task


    def process_arguments = ['sync'] + super


    def externalize = super.merge(operation: :synchronize)


    def show_operation = super + 'synchronize'


  end


  class Rclone::Equalize < Rclone::Task


    def process_arguments = ['bisync', '--resync'] + super


    def externalize = super.merge(operation: :equalize)


    def show_operation = super + 'equalize'


    def show_direction = '<->'


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


  end


  class Restic::Task < Task


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
      cms = cmd.collect(&:shellescape).join(' ')
      puts cms if Bitferry.verbosity == :verbose
      log.info(cms)
      if simulate
        log.info('(simulated)')
        true
      else
        wd = Dir.getwd unless chdir.nil?
        begin
          Dir.chdir(chdir) unless chdir.nil?
          status = Open3.pipeline(cmd).first
          raise "restic exit code #{status.exitstatus}" unless status.success?
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
        tag: hash.fetch(:tag),
        modified: hash.fetch(:modified, DateTime.now)
      )
      super(hash)
    end


  end


  class Restic::Backup < Restic::Task


    PROCESS = {
      'default' => []
    }


    FORGET = {
      'default' => ['--prune', '--keep-within-hourly', '24h', '--keep-within-daily', '7d', '--keep-within-weekly', '30d', '--keep-within-monthly', '1y', '--keep-within-yearly', '100y']
    }


    CHECK = {
      'fast' => [],
      'default' => [],
      'full' => ['--read-data']
    }


    attr_reader :process_options
    attr_reader :forget_options
    attr_reader :check_options


    def create(*, format: nil, process: nil, forget: nil, check: nil, **opts)
      super(*, **opts)
      @format = format
      @process_options = process.nil? ? [] : process
      @forget_options = forget
      @check_options = check
    end


    def show_status = "#{show_operation} #{directory.show_status} #{show_direction} #{repository.show_status}"


    def show_operation = 'encrypt+backup'


    def show_direction = '-->'


    def process
      begin
        log.info("processing task #{tag}")
        execute('backup', '.', '--tag', tag, '--exclude', Volume::STORAGE, '--exclude', Volume::STORAGE_, *process_options, *common_options_simulate, chdir: directory.root)
        unless check_options.nil?
          log.info("checking repository in #{repository.root}")
          execute('check', *check_options, *common_options)
        end
        unless forget_options.nil?
          log.info("performing repository maintenance tasks in #{repository.root}")
          execute('forget', *forget_options.collect(&:to_s), *common_options_simulate)
        end
        true
      rescue
        false
      end
    end


    def common_options_simulate = common_options + [Bitferry.simulate? ? '--dry-run' : nil].compact


    def externalize
      restic = {
        process: process_options.empty? ? nil : process_options,
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
      @process_options = opts.fetch(:process, [])
      @forget_options = opts.fetch(:forget, nil)
      @check_options = opts.fetch(:check, nil)
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


  class Restic::Restore < Restic::Task


    attr_reader :restore_options


    def create(*, restore: [], **opts)
      super(*, **opts)
      @restore_options = restore
    end


    def show_status = "#{show_operation} #{repository.show_status} #{show_direction} #{directory.show_status}"


    def show_operation = 'decrypt+restore'


    def show_direction = '-->'


    def externalize

      restic = {
        restore: restore_options.empty? ? nil : restore_options
      }.compact
      super.merge({
        operation: :restore,
        restic: restic.empty? ? nil : restic
      }.compact)
    end


    def restore(hash)
      super
      opts = hash.fetch(:rclone, {})
      @restore_options = opts.fetch(:restore, [])
    end


    def process
      log.info("processing task #{tag}")
      begin
        execute('restore', 'latest', '--target', '.', *restore_options, *common_options, simulate: Bitferry.simulate?, chdir: directory.root)
        true
      rescue
        false
      end
    end


  end


  Task::ROUTE = {
    'copy' => Rclone::Copy,
    'update' => Rclone::Update,
    'synchronize' => Rclone::Synchronize,
    'equalize' => Rclone::Equalize,
    'backup' => Restic::Backup,
    'restore' => Restic::Restore
  }


  class Endpoint


    def self.restore(hash)
      endpoint = allocate
      endpoint.send(:restore, hash)
      endpoint
    end


  end


  class Endpoint::Local < Endpoint


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


  class Endpoint::Rclone < Endpoint
    # TODO
  end


  class Endpoint::Bitferry < Endpoint


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
      @path = Pathname.new(hash.fetch(:path))
    end


    def externalize
      {
        endpoint: :bitferry,
        volume: volume_tag,
        path: path
      }
    end


    def show_status = intact? ? ":#{volume_tag}:#{path}" : ":{#{volume_tag}}:#{path}"


    def intact? = !Volume[volume_tag].nil?


    def refers?(volume) = volume.tag == volume_tag


    def generation
      v = Volume[volume_tag]
      v ? v.generation : 0
    end


  end


  Endpoint::ROUTE = { 'local' => Endpoint::Local, 'rclone' => Endpoint::Rclone, 'bitferry' => Endpoint::Bitferry }


  reset


end
