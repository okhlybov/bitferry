require 'fox16'
require 'bitferry'

include Fox

class UI < FXMainWindow

  def initialize(app)
    super(@app = app, 'BitferryFX', width: 400, padding: 4)
    FXToolTip.new(app)
    @progress = FXProgressBar.new(self, padding: 4, height: 16, opts: LAYOUT_FILL_X | JUSTIFY_BOTTOM | LAYOUT_FIX_HEIGHT)
    @simulate = FXCheckButton.new(self, "&Simulation mode (dry run)\tPrevent operations from making any on-disk changes")
      @simulate.checkState = Bitferry.simulate?
    buttons = FXPacker.new(self, opts: LAYOUT_FILL_X | LAYOUT_SIDE_BOTTOM | PACK_UNIFORM_WIDTH | FRAME_SUNKEN)
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
    @progress.progress = 0
    Bitferry.restore
  end

  def create
    super
    show(PLACEMENT_SCREEN)
  end

end

FXApp.new do |app|
  Bitferry.verbosity = :verbose
  UI.new(app)
  app.create
  app.run
end