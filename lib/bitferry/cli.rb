#!/usr/bin/env ruby


require 'io/console'
require 'bitferry'
require 'gli'


include GLI::App


include Bitferry


$failure = false


program_desc 'File synchronization/backup automation tool'


version Bitferry::VERSION


arguments :strict
subcommand_option_handling :normal


desc 'Be as quiet as possible'
switch [:quiet, :q], { negatable: false }


desc 'Be more verbose'
switch [:verbose, :v], { negatable: false }


desc 'Simulation mode (make no on-disk changes)'
switch ['dry-run', :n], { negatable: false }


desc 'Debug mode with lots of information'
switch [:debug, :d], { negatable: false }


desc 'Show status information'
command [:show, :info] do |c|
  c.action do
    unless (xs = Volume.intact).empty?
      puts '# Intact volumes'
      puts
      xs.each do |volume|
        puts "  #{volume.tag}    #{volume.root}"
      end
    end
    unless (xs = Task.intact).empty?
      puts
      puts '# Intact tasks'
      puts
      xs.each do |task|
        puts "  #{task.tag}    #{task.show_status}"
      end
    end
    unless (xs = Task.stale).empty?
      puts
      puts '# Stale tasks'
      puts
      xs.each do |task|
        puts "  #{task.tag}    #{task.show_status}"
      end
    end
  end
end


desc 'Process intact tasks'
command :process do |p|
  p.action { $failure = true unless Bitferry.process }
end


def decode_endpoint(root)
  x = Bitferry.endpoint(root)
  raise ArgumentError, "no volume encompasses specified path #{root}" if x.nil?
  x
end


desc 'Create entity (volume, task)'
command [:new, :create] do |c|


  c.arg 'root'
  c.desc 'Create new volume'
  c.command :volume do |e|
    e.switch :force, { desc: 'Allow overwriting existing volume storage', negatable: false }
    e.action do |gopts, opts, args|
      Volume.force_overwrite = true if opts[:force]
      Volume.new(args.first)
    end
  end


  def create_rclone_task(task, *args, **opts)
    begin
      task.new(decode_endpoint(args[0]), decode_endpoint(args[1]), encryption: decode_rclone_encryption(**opts), preserve_metadata: opts[:metadata])
    rescue => e
      log.error(e.message)
      raise
    end
  end
  
  
  def self.new_task_args(x)
    x.arg '[remote:]source'
    x.arg '[remote:]destination'
  end


  def self.new_task_opts(x)
    x.flag [:transformer, :t], { desc: 'File name transformer (-t- to disable transformation)', default_value: :encrypter }
    x.flag [:encoder, :c], { desc: 'File name encoder', default_value: :base32 }
    x.switch [:unicode, :u], { desc: 'Force unicode-aware file name encoding (overrides -c)', negatable: false }
    x.switch [:encrypt, :e], { desc: 'Encrypt files in destination', negatable: false }
    x.switch [:decrypt, :d], { desc: 'Decrypt files from source', negatable: false }
    x.switch [:metadata, :M], { desc: 'Preserve file metadata', default_value: true }
  end
  
  

  def self.selector(*args, **opts)
    x = nil
    args.each do |a|
      if opts[a]
        raise "expected either switch of #{args.join(', ')}" unless x.nil?
        x = a
      end
    end
    x
  end


  def self.obtain_password(**opts)
    if $stdin.tty?
      p1 = IO.console.getpass 'Enter password:'
      p2 = IO.console.getpass 'Repeat password:'
      raise 'passwords do not match' unless p1 == p2
      p1
    else
      $stdin.readline.strip!
    end
  end


  def self.decode_rclone_encryption(**opts)
    x = nil
    m = selector(:encrypt, :decrypt, **opts)
    unless m.nil?
      e = opts[:unicode] ? :base32768 : opts[:encoder].intern
      t = opts[:transformer] == '-' ? false : opts[:transformer].intern
      x = Rclone::Encryption::ROUTE.fetch(m).new(obtain_password(**opts), name_encoder: e, name_transformer: t)
    end
    x
  end


  c.desc 'Create new task'
  c.command :task do |e|


  new_task_args e
  e.desc 'Create new copy task'
  e.command :copy do |t|
    new_task_opts t
    t.action do |gopts, opts, args|
      create_rclone_task(Rclone::Copy, *args, **opts)
    end
  end


  new_task_args e
  e.desc 'Create new update task'
  e.command :update do |t|
    new_task_opts t
    t.action do |gopts, opts, args|
      create_rclone_task(Rclone::Update, *args, **opts)
    end
  end


  new_task_args e
  e.desc 'Create new synchronization task'
  e.command :synchronize do |t|
    new_task_opts t
    t.action do |gopts, opts, args|
      create_rclone_task(Rclone::Synchronize, *args, **opts)
    end
  end


end


end


desc 'Delete entity (volume, task)'
command [:delete, :remove] do |c|


  def self.delete_args(x)
    x.arg 'tag', :multiple
  end


  delete_args(c)
  c.desc 'Delete volume'
  c.command :volume do |e|
    e.switch :wipe, { desc: 'Wipe entire volume directory', negatable: false }
    e.action do |gopts, opts, args|
      Volume.force_wipe = true if opts[:wipe]
      args.each do |partial|
        volumes = Volume.lookup(partial)
        case volumes.size
        when 0 then log.warn("no intact volume matching (partial) tag #{partial}")
        when 1
        else
          tags = volumes.collect { |v| v.tag }.join(', ')
          log.fatal("multiple intact volumes matching (partial) tag #{partial}: #{tags}")
          raise
        end
        volumes.each(&:delete)
      end
    end
  end


  delete_args(c)
  c.desc 'Delete task'
  c.command :task do |e|
    e.action do |gopts, opts, args|
      args.each do |partial|
        tasks = Task.lookup(partial)
        case tasks.size
        when 0 then log.warn("no task matching (partial) tag #{partial}")
        when 1
        else
          tags = tasks.collect { |task| task.tag }
          log.fatal("multiple tasks matching (partial) tag #{partial}: #{tags.join(', ')}")
          raise
        end
        tasks.each(&:delete)
      end
    end
  end
end


pre do |gopts, cmd, opts, args|
  Bitferry.log.level = Logger::DEBUG if gopts[:debug] || $DEBUG
  Bitferry.simulate = true if gopts[:'dry-run']
  Bitferry.verbosity = :verbose if gopts[:verbose]
  Bitferry.verbosity = :quiet if gopts[:quiet]
  $failure = true unless Bitferry.restore
  true
end


post do |gopts, cmd, opts, args|
  $failure = true unless Bitferry.commit
  raise 'failure(s) reported' if $failure
  true
end


exit run(ARGV)