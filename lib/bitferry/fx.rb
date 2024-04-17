require 'fox16'
require 'stringio'
require 'bitferry'


include Fox


class Output

  def initialize(app, output)
    @app = app
    @output = output
    @output.text = nil
  end

  def puts(str) = write(str, "\n")

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
        tasks = FXText.new(tabs)
      volumes_tab = FXTabItem.new(tabs, 'Volumes')
        volumes = FXText.new(tabs)
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
