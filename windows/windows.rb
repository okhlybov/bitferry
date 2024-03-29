# A rather hacky way to retrieve the interpreter location on Windows
# (instead of a call to Kernel32::GetModuleFileName)
require 'pathname'
path = ENV['PATH']
site_ruby = $:.filter { |x| /site_ruby/ =~ x }.first
bin = Pathname.new(site_ruby).join(*['..']*4, 'bin').realdirpath
ENV['PATH'] = "#{bin};#{path}"