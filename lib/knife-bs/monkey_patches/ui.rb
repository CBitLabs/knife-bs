#
# Author: BitSight Technologies (<ops@bitsighttech.com>)
#

#
# == $Chef::Knife::UI (Patch)
# Patches $ui.err to maintain a list of warnings and errors
# and display them at the end of the knife run
#

require 'chef/knife/core/ui'
require 'terminal-table'
require 'knife-bs/monkey_patches/table'

class Chef
  class Knife
    class UI

      alias old_err err
      def err(message)
        old_err(message)
        messages << message
      end

      def status(code, fg, message)
        msg("[#{color(code.to_s, fg)}] #{message}")
      end

      unless method_defined?(:messages)
        def messages
          @@messages ||= []
        end
      end

      unless method_defined?(:print_messages)
        def print_messages
          unless messages.size < 1
            knife_cmd = "knife #{ARGV.join(' ')}"
            table = Terminal::Table.new do |t|
              t.title = "Error(s) Raised During:\n#{knife_cmd}"
              messages.each_with_index do |message, index|
                t.add_row [message]
                t.add_separator unless index == messages.size - 1
              end
            end
            puts table
          else
            msg "\n\nNo errors raised!"
          end
        end
      end

      unless method_defined?(:unpatch!)
        def unpatch!
          alias err old_err
        end
      end
    end
  end
end
