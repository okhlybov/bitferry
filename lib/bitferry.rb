require 'json'
require 'date'
require 'logger'
require 'pathname'
require 'fileutils'


module Bitferry


  module Logging
    @@log = Logger.new($stderr)
    @@log.progname = :bitferry
  end


  include Logging


  VERSION = '0.0.1'


  def self.tag = format('%08x', 2**32*rand)


  def self.restore
    TODO
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
    Volume.reset
    Task.reset
  end


  @simulate = false
  def self.simulate? = @simulate
  def self.simulate=(mode) @simulate = mode end


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
      volume = allocate
      volume.send(:restore, root)
      register(volume)
    end


    def initialize(root, tag: Bitferry.tag, timestamp: DateTime.now)
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
      raise IOError, "Wrong volume storage #{storage}" unless json.has_key?(:bitferry) && json[:bitferry] == "0"
      initialize(root, tag: json[:tag], timestamp: DateTime.parse(json[:timestamp]))
      # TODO load tasks
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


    def untouch = @generation = [source.generation, destination.generation].min


    def self.new(source, destination)
      task = allocate
      task.send(:initialize, source, destination)
      task.touch
      register(task)
    end


    def self.restore(hash)
      task = ROUTE[hash['tag']].restore(root)
      task.untouch # Task being restored should not trigger modification status of the volumes it refers to
      task
    end



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