require 'clamp'
require 'bitferry'
require 'io/console'


Endpoint = %{
  The endpoint may be one of:
  * directory -- absolute or relative local directory (/data, ../source, c:\\data)
  * local:directory, :directory -- absolute local directory (:/data, local:c:\\data)
  * :tag:directory -- path relative to the intact volume matched by (partial) tag (:fa2c:source/data)

  The former case resolves specified directory againt an intact volume to make it volume-relative.
  It is an error if there is no intact volume that encompasses specified directory.
  The local: directory is left as is (not resolved against volumes).
  The :tag: directory is bound to the specified volume.
}


Encryption = %{
  The encryption mode is controlled by --encrypt or --decrypt options.
  The mandatory password will be read from the standard input channel (pipe or keyboard).
}


$process = nil
$encryption = nil
$include = []
$exclude = []


def ext_globs(exts) = exts.split(',').collect { |ext| "*.#{ext}" }


def setup_task(x, include: true)
  x.option ['-i'], 'EXTS', 'Include file extensions (comma-separated list)', multivalued: true, attribute_name: :include_exts do |exts|
    $include << ext_globs(exts)
  end if include
  x.option ['-x'], 'EXTS', 'Exclude file extensions (comma-separated list)', multivalued: true, attribute_name: :exclude_exts do |exts|
    $exclude << ext_globs(exts)
  end
  x.option ['--include'], 'GLOBS', 'Include path specifications (comma-separated list)', multivalued: true, attribute_name: :include do |globs|
    $include << globs.split(',')
  end if include
  x.option ['--exclude'], 'GLOBS', 'Exclude path specifications (comma-separated list)', multivalued: true, attribute_name: :exclude do |globs|
    $exclude << globs.split(',')
  end
end


def setup_rclone_task(x)
  x.parameter 'SOURCE', 'Source endpoint specifier'
  x.parameter 'DESTINATION', 'Destination endpoint specifier'
  x.option '-e', :flag, 'Encrypt files in destination using default profile (alias for -E default)', attribute_name: :e do
    $encryption = Bitferry::Rclone::Encrypt
    $profile = :default
  end
  x.option '-d', :flag, 'Decrypt source files using default profile (alias for -D default)', attribute_name: :d do
    $encryption = Bitferry::Rclone::Decrypt
    $profile = :default
  end
  x.option '-u', :flag, 'Apply extended (unicode) encryption profile options (alias for -E extended / -D extended)', attribute_name: :u do
    $extended = true
  end
  x.option ['--process', '-X'], 'OPTIONS', 'Extra task processing profile/options' do |opts|
    $process = opts
  end
  x.option ['--encrypt', '-E'], 'OPTIONS', 'Encrypt files in destination using specified profile/options' do |opts|
    $encryption = Bitferry::Rclone::Encrypt
    $profile = opts
  end
  x.option ['--decrypt', '-D'], 'OPTIONS', 'Decrypt source files using specified profile/options' do |opts|
    $encryption = Bitferry::Rclone::Decrypt
    $profile = opts
  end
  setup_task(x)
end


def create_rclone_task(task, *args, **opts)
  task.new(*args,
    process: $process,
    encryption: $encryption&.new(obtain_password, process: $extended ? :extended : $profile),
    include: $include.flatten.uniq, exclude: $exclude.flatten.uniq,
    **opts
  )
end


def bitferry(&code)
  begin
    Bitferry.restore
    result = yield
    exit(Bitferry.commit && result ? 0 : 1)
  rescue => e
    Bitferry.log.fatal(e.message)
    exit(1)
  end
end


def obtain_password
  if $stdin.tty?
    p1 = IO.console.getpass 'Enter password:'
    p2 = IO.console.getpass 'Repeat password:'
    raise 'passwords do not match' unless p1 == p2
    p1
  else
    $stdin.readline.strip!
  end
end


Bitferry.ui = :cli
Bitferry.log.level = Logger::DEBUG if $DEBUG


Clamp do


  self.default_subcommand = 'show'


  option '--version', :flag, 'Print version' do
    $stdout.puts Bitferry::VERSION
    exit
  end


  option ['--verbose', '-v'], :flag, 'Extensive logging' do
    Bitferry.verbosity = :verbose
  end


  option ['--quiet', '-q'], :flag, 'Disable logging' do
    Bitferry.verbosity = :quiet
  end


  option ['--dry-run', '-n'], :flag, 'Simulation mode (make no on-disk changes)' do
    Bitferry.simulate = true
  end


  subcommand ['show', 'info', 'i'], 'Print state' do
    def execute
      Bitferry.restore
      unless (xs = Bitferry::Volume.intact).empty?
        $stdout.puts '# Intact volumes'
        $stdout.puts
        xs.each do |volume|
          $stdout.puts "  #{volume.tag}    #{volume.root}"
        end
      end
      unless (xs = Bitferry::Task.intact).empty?
        $stdout.puts
        $stdout.puts '# Intact tasks'
        $stdout.puts
        xs.each do |task|
          $stdout.puts "  #{task.tag}    #{task.show_status}"
        end
      end
      if !(xs = Bitferry::Task.stale).empty? && Bitferry.verbosity == :verbose
        $stdout.puts
        $stdout.puts '# Stale tasks'
        $stdout.puts
        xs.each do |task|
          $stdout.puts "  #{task.tag}    #{task.show_status}"
        end
      end
    end
  end


  subcommand ['create', 'c'], 'Create entity' do


    subcommand ['volume', 'v'], 'Create volume' do
      banner %{
        Create new volume in specified directory. Create directory if it does not exist.
        Refuse to overwrite existing volume storage unless --force is specified.
      }
      option '--force', :flag, 'Overwrite existing volume storage in target directory'
      parameter 'DIRECTORY', 'Target volume directory'
      def execute
        bitferry { Bitferry::Volume.new(directory, overwrite: force?) }
      end
    end


    subcommand ['task', 't'], 'Create task' do


      subcommand ['copy', 'c'], 'Create copy task' do
        banner %{
          Create source --> destination file copy task.

          The task operates recursively on two specified endpoints.
          This task unconditionally copies all source files overwriting existing files in destination.

          #{Endpoint}

          #{Encryption}

          This task employs the Rclone worker.
        }
        setup_rclone_task(self)
        def execute
          bitferry { create_rclone_task(Bitferry::Rclone::Copy, source, destination) }
        end
      end


      subcommand ['update', 'u'], 'Create update task' do
        banner %{
          Create source --> destination file update (freshen) task.

          The task operates recursively on two specified endpoints.
          This task copies newer source files while skipping unchanged files in destination.

          #{Endpoint}

          #{Encryption}

          This task employs the Rclone worker.
        }
        setup_rclone_task(self)
        def execute
          bitferry { create_rclone_task(Bitferry::Rclone::Update, source, destination) }
        end
      end


      subcommand ['synchronize', 'sync', 's'], 'Create one way sync task' do
        banner %{
          Create source --> destination one way file synchronization task.

          The task operates recursively on two specified endpoints.
          This task copies newer source files while skipping unchanged files in destination.
          Also, it deletes destination files which are non-existent in source.

          #{Endpoint}

          #{Encryption}

          This task employs the Rclone worker.
        }
        setup_rclone_task(self)
        def execute
          bitferry { create_rclone_task(Bitferry::Rclone::Synchronize, source, destination) }
        end
      end


      subcommand ['equalize', 'bisync', 'e'], 'Create two way sync task' do
        banner %{
          Create source <-> destination two way file synchronization task.

          The task operates recursively on two specified endpoints.
          This task retains only the most recent versions of files on both endpoints.
          Opon execution both endpoints are left identical.

          #{Endpoint}

          #{Encryption}

          This task employs the Rclone worker.
        }
        setup_rclone_task(self)
        def execute
          bitferry { create_rclone_task(Bitferry::Rclone::Equalize, source, destination) }
        end
      end


      subcommand ['backup', 'b'], 'Create backup task' do
        banner %{
          Create source --> repository incremental backup task.
          This task employs the Restic worker.
        }
        option '--force', :flag, 'Force overwriting existing repository' do $format = true end
        option ['--attach', '-a'], :flag, 'Attach to existing repository' do $format = false end
        option '-f', :flag, 'Apply default snapshot retention policy options (alias for -F default)', attribute_name: :f do $forget = :default end
        option '-c', :flag, 'Apply default repository checking options (alias for -C default)', attribute_name: :c do $check = :default end
        option ['--process', '-X'], 'OPTIONS', 'Extra task processing profile/options' do |opts| $process = opts end
        option ['--forget', '-F'], 'OPTIONS', 'Snapshot retention policy with profile/options' do |opts| $forget = opts end
        option ['--check', '-C'], 'OPTIONS', 'Repository checking with profile/options' do |opts| $check = opts end
        parameter 'SOURCE', 'Source endpoint specifier'
        parameter 'REPOSITORY', 'Destination repository endpoint specifier'
        setup_task(self, include: false)
        def execute
          bitferry {
            Bitferry::Restic::Backup.new(
              source, repository, obtain_password,
              format: $format,
              process: $process,
              check: $check,
              forget: $forget,
              exclude: $exclude.flatten.uniq
            )
          }
        end
      end


      subcommand ['restore', 'r'], 'Create restore task' do
        banner %{
          Create repository --> destination restore task.
          This task employs the Restic worker.
        }
        option ['--process', '-X'], 'OPTIONS', 'Extra task processing profile/options' do |opts| $process = opts end
        parameter 'REPOSITORY', 'Source repository endpoint specifier'
        parameter 'DESTINATION', 'Destination endpoint specifier'
        setup_task(self)
        def execute
          bitferry {
            Bitferry::Restic::Restore.new(
              destination, repository, obtain_password,
              process: $process,
              include: $include.flatten.uniq, exclude: $exclude.flatten.uniq
            )
          }
        end
      end


    end


  end


  subcommand ['delete', 'd'], 'Delete entity' do


    subcommand ['volume', 'v'], 'Delete volume' do
      banner %{
        Delete volumes matched by specified (partial) tags.
        There may be multiple tags but each tag must match at most one volume.
        This command deletes the volume storage file only with the rest of data left intact.
      }
      option '--wipe', :flag, 'Wipe target directory upon deletion'
      parameter 'TAG ...', 'Volume tags', attribute_name: :tags
      def execute
        bitferry { Bitferry::Volume.delete(*tags, wipe: wipe?) }
      end
    end


    subcommand ['task', 't'], 'Delete task' do
      banner %{
        Delete tasks matched by specified (partial) tags.
        There may be multiple tags but each tag must match at most one task.
      }
      parameter 'TAG ...', 'Task tags', attribute_name: :tags
      def execute
        bitferry { Bitferry::Task.delete(*tags) }
      end
    end


  end


  subcommand ['process', 'x'], 'Process tasks' do
    banner %{
      Process tasks matched by specified (partial) tags.
      If no tags are given, process all intact tasks.
    }
    parameter '[TAG] ...', 'Task tags', attribute_name: :tags
    def execute
      bitferry { Bitferry.process(*tags) }
    end
  end


end
