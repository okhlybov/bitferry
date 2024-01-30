require 'json'
require 'date'
require 'pathname'
require 'fileutils'


module Bitferry

  VERSION = '0.0.1'

  def self.tag = format('%08x', 2**32*rand)

  def self.restore
    TODO
  end

  def self.commit
    result = true
    Volume.registered.each do |v|
      begin
        v.commit
      rescue IOError
         # TODO log errors
         result = false
      end
    end
    result
  end

  def self.reset
    Volume.reset
    Task.reset
  end

  @simulate = false

  def self.simulate? = @simulate

  def self.simulate=(mode) @simulate = mode end

  class Volume

    STORAGE  = '.bitferry'
    STORAGE_ = '.bitferry~'

    attr_reader :tag

    attr_reader :generation

    attr_reader :root

    @force_overwrite = false

    def self.force_overwrite? = @force_overwrite

    def self.force_overwrite=(mode) @force_overwrite = mode end

    def self.[](tag) = @@registry[tag]

    def initialize(root, tag: Bitferry.tag, timestamp: DateTime.now)
      @tag = tag
      @timestamp = timestamp
      @root = Pathname.new(root).realdirpath
      @state = :pristine
      @modified = true
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

    def modified? = @modified || tasks.any? { |t| t.generation > generation }

    def touch
      x = tasks.collect { |t| t.generation }.max
      @generation = x ? x + 1 : 0
      @modified = true
    end

    private def commit_tasks = tasks.each(&:commit)

    private def committed
      x = tasks.collect { |t| t.generation }.min
      @generation = (x ? x : 0) - 1
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

    def self.new(root)
      volume = allocate
      volume.send(:initialize, root)
      volume.touch # Instruct to write new volume even if it is empty
      register(volume)
    end

    def self.restore(root)
      obj = allocate
      obj.send(:restore, root)
      register(obj)
    end

    def self.register(volume) = @@registry[volume.tag] = volume

    def self.registered = @@registry.values

    private def restore(root)
      initialize(root) # TODO
      @state = :intact
      @modified = false
    end


  end

  class Task

    attr_reader :source, :destination

    attr_reader :tag

    attr_reader :generation

    def initialize(source, destination, tag: Bitferry.tag, timestamp: DateTime.now)
      @tag = tag
      @timestamp = timestamp
      @source = source
      @destination = destination
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

    def untouch = @generation = [source.generation, destination.generation].min - 1

    def self.new(source, destination)
      task = allocate
      task.send(:initialize, source, destination)
      task.touch
      register(task)
    end

    def self.[](tag) = @@registry[tag]

    def self.registered = @@registry.values

    def self.reset = @@registry = {}

    def self.register(task) = @@registry[task.tag] = task

    def self.restore(hash)
      task = TASKS[hash['tag']].restore(root)
      task.untouch # Task being restored should not trigger modification status of the volumes it refers to
      task
    end

  end

  class Task::Copy < Task

    def to_ext = super.merge(task: :copy)

    def self.restore(hash)
      TODO
    end

    def commit
      # TODO
    end
  end

  Task::TASKS = { 'copy' => Task::Copy }

  class Endpoint
  end

  class Endpoint::Local < Endpoint

    attr_reader :root

    def initialize(root) = @root = Pathname.new(root)

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

    def initialize(volume, path)
      @volume_tag = volume.tag
      @path = Pathname.new(path) # TODO ensure relative
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

  end

  reset

end