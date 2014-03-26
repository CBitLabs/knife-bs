#
# Author: BitSight Technologies (<ops@bitsighttech.com>)
#

#
# == $stdout (Patch)
# Patches $stdout.write to write a log file of the Knife run to
# the present working directory. Adds $stdout.unpatch since logfile 
# is created by default and disabled through the `-b` or `--no_bslog` 
# option.
#

require 'chef/bs_utils/bs_logging'

class << $stdout
  alias orig_write write
  def write string
    BsUtils::BsLogging.log_file.write string
    super
  end
  def unpatch
    alias write orig_write
  end
end
