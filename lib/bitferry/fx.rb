require 'fox16'
require 'stringio'
require 'bitferry'


include Fox


class Output < StringIO

  def initialize(app, output)
    super('rw+')
    @app = app
    @output = output
    @output.text = nil
  end

  def write(*args) = @app.runOnUiThread { @output.appendText(args.join) }

  def flush = nil

end


class UI < FXMainWindow

  def initialize(app)
    super(@app = app, 'BitferryFX', width: 400, height: 300)
    top_frame = FXVerticalFrame.new(self, opts: LAYOUT_FILL)
      tabs = FXTabBook.new(top_frame, opts: LAYOUT_FILL)
        output_tab = FXTabItem.new(tabs, 'Output')
          @output = FXText.new(tabs)
      tasks_tab = FXTabItem.new(tabs, 'Tasks')
        @tasks = FXTable.new(tabs)
        @tasks.tableStyle |= TABLE_COL_SIZABLE | TABLE_NO_COLSELECT | TABLE_READONLY
        @tasks.rowHeaderMode = LAYOUT_FIX_WIDTH
        @tasks.rowHeaderWidth = 0
      volumes_tab = FXTabItem.new(tabs, 'Volumes')
        @volumes = FXTable.new(tabs)
        @volumes.tableStyle |= TABLE_COL_SIZABLE | TABLE_NO_COLSELECT | TABLE_READONLY
        @volumes.rowHeaderMode = LAYOUT_FIX_WIDTH
        @volumes.rowHeaderWidth = 0
      @progress = FXProgressBar.new(top_frame, height: 16, opts: LAYOUT_FILL_X | LAYOUT_FIX_HEIGHT)
      controls = FXPacker.new(top_frame, opts: LAYOUT_FILL_X)
        @simulate = FXCheckButton.new(controls, "&Simulation mode (dry run)\tPrevent operations from making any on-disk changes")
          @simulate.checkState = Bitferry.simulate?
      buttons = FXPacker.new(top_frame, opts: LAYOUT_FILL_X | PACK_UNIFORM_WIDTH | FRAME_SUNKEN)
        @process = FXButton.new(buttons, "&Process\tProcess all intact tasks", opts: BUTTON_NORMAL | BUTTON_INITIAL | BUTTON_DEFAULT | LAYOUT_SIDE_LEFT)
          @process.connect(SEL_COMMAND) { process }
          @process.setFocus
        @quit = FXButton.new(buttons, "&Quit\tStop any pending operations and exit", opts: BUTTON_NORMAL | LAYOUT_SIDE_RIGHT)
          @quit.connect(SEL_COMMAND) { exit }
        @reload = FXButton.new(buttons, "&Reload\tReread volumes and tasks to capture volume changes", opts: BUTTON_NORMAL | LAYOUT_SIDE_RIGHT)
          @reload.connect(SEL_COMMAND) { reset }
    @sensible = [@process, @reload] # Controls which must be disabled during processing
    reset
  end

  def process
    Bitferry.simulate = @simulate.checked?
    @progress.setBarColor(:blue)
    @progress.progress = 0
    @output.text = nil
    Thread.new {
      @app.runOnUiThread { @sensible.each(&:disable) }
      begin
        Bitferry.process { |total, processed, failed|
          @app.runOnUiThread {
            @progress.setBarColor(:red) if failed > 0
            @progress.progress = processed
            @progress.total = total
          }
        }
      ensure
        @app.runOnUiThread { @sensible.each(&:enable) }
      end
    }
  end

  def reset
    Bitferry.restore
    @progress.progress = 0
    $stdout = Output.new(@app, @output)
    Bitferry::Logging.log = log = Logger.new($stdout)
    log.progname = :bitferryfx
    log.level = Logger::WARN
    #
    @volumes.setTableSize(Bitferry::Volume.intact.size, 2)
    @volumes.setColumnText(0, 'Volume')
    @volumes.setColumnText(1, 'Root')
    i = 0
    Bitferry::Volume.intact.each do |v|
      @volumes.setItemText(i, 0, v.tag)
      @volumes.setItemText(i, 1, v.root.to_s)
      i += 1
    end
    #
    @tasks.setTableSize(Bitferry::Task.intact.size, 4)
    @tasks.setColumnText(0, 'Task')
    @tasks.setColumnText(1, 'Operation')
    @tasks.setColumnText(2, 'Source')
    @tasks.setColumnText(3, 'Destination')
    i = 0
    Bitferry::Task.intact.each do |t|
      @tasks.setItemText(i, 0, t.tag)
      @tasks.setItemText(i, 1, t.show_operation)
      @tasks.setItemText(i, 2, t.source.show_status)
      @tasks.setItemText(i, 3, t.destination.show_status)
      i += 1
    end
    #
  end

  def create
    super
    show(PLACEMENT_SCREEN)
  end

end


FXApp.new do |app|
  Bitferry.verbosity = :verbose
  Bitferry.ui = :gui
  UI.new(app)
  app.create
  app.run
end
