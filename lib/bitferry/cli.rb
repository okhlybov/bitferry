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


def setup_rclone_task(x)
  x.parameter 'SOURCE', 'Source endpoint specifier'
  x.parameter 'DESTINATION', 'Destination endpoint specifier'
  x.option ['--process'], 'OPTIONS', 'Extra processing options' do |opts| $process = opts end
  x.option ['--encrypt', '-e'], 'OPTIONS', 'Encrypt files in destination' do |opts|
    $encryption = Bitferry::Rclone::Encrypt.new(obtain_password, process: decode_options(opts, Bitferry::Rclone::Encryption::PROCESS))
  end
  x.option ['--decrypt', '-d'], 'OPTIONS', 'Decrypt source files' do |opts|
    $encryption = Bitferry::Rclone::Decrypt.new(obtain_password, process: decode_options(opts, Bitferry::Rclone::Encryption::PROCESS))
  end
end


def create_rclone_task(type, *args, **opts)
  type.new(*args, process: decode_options($process, Bitferry::Rclone::Task::PROCESS), encryption: $encryption, **opts)
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


def decode_options(opts, hash)
  # * nil -> nil
  # * default -> hash[default]
  # * --foo,bar -> [--foo, bar]
  opts.nil? ? nil : (opts.start_with?('-') ? opts.split(',') : hash.fetch(opts))
end


Bitferry.log.level = Logger::DEBUG if $DEBUG


Clamp do


  self.default_subcommand = 'show'


  option '--version', :flag, 'Print version' do
    puts Bitferry::VERSION
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
        puts '# Intact volumes'
        puts
        xs.each do |volume|
          puts "  #{volume.tag}    #{volume.root}"
        end
      end
      unless (xs = Bitferry::Task.intact).empty?
        puts
        puts '# Intact tasks'
        puts
        xs.each do |task|
          puts "  #{task.tag}    #{task.show_status}"
        end
      end
      unless (xs = Bitferry::Task.stale).empty?
        puts
        puts '# Stale tasks'
        puts
        xs.each do |task|
          puts "  #{task.tag}    #{task.show_status}"
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


      subcommand ['backup', 'b'], 'Create backup task' do
        banner %{
          Create source --> repository incremental backup task.
          This task employs the Restic worker.
        }
        option ['--process'], 'OPTIONS', 'Extra processing options' do |opts| $process = opts end
        option ['--forget'], 'OPTIONS', 'Repository forgetting (snapshot retention policy) options' do |opts| $forget = opts end
        option ['--check'], 'OPTIONS', 'Repository checking options' do |opts| $check = opts end
        option '--force', :flag, 'Force overwriting existing repository' do $format = true end
        option ['--attach', '-a'], :flag, 'Attach to existing repository' do $format = false end
        parameter 'SOURCE', 'Source endpoint specifier'
        parameter 'REPOSITORY', 'Destination repository endpoint specifier'
        def execute
          bitferry {
            Bitferry::Restic::Backup.new(
              source, repository, obtain_password,
              format: $format,
              process: decode_options($process, Bitferry::Restic::Backup::PROCESS),
              check: decode_options($check, Bitferry::Restic::Backup::CHECK),
              forget: decode_options($forget, Bitferry::Restic::Backup::FORGET)
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