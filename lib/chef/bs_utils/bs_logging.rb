#
# Author: BitSight Technologies (<ops@bitsighttech.com>)
#

# == BsUtils::BsLogging
# Logging utility for knife-bs. Adds the stdout monkey-patch
# to save knife run to disk.
# Patches $stdout.write to write a log file of the Knife run to
# the present working directory. Logfile is created by default.
#

require 'knife-bs/version'
module BsUtils
  module BsLogging
    # Timestamp for log file name
    @stamp = "#{::Time.now.strftime '%Y-%m-%d_%H-%M-%S'}"
    @logname = "knife_#{ARGV.join("_").delete('/').shellescape}_#{@stamp}"
    @@was_included_prior = false

    # Callback which is run when module is included
    #
    # * Adds log header once
    # * Adds monkey-patched $stdout to including class/module
    def self.included(includer)
      # Only write the log header once
      unless @@was_included_prior
        self.make_log_dir
        self.add_log_header
        $stdout.write "\n\nLogfile for this run is located at: #{self.log_file.path}\n\n"
        @@was_included_prior = true
      end
      includer.class_eval do
        require 'knife-bs/monkey_patches/stdout'
      end
    end

    # * Restores original $stdout#write
    # * Deletes log file if exists
    def self.disable
      $stdout.unpatch
      ::File.delete(self.log_file) if ::File.exists?(self.log_file)
    end

    # Accessor for @@log_file
    def self.log_file
      #shorten filename for 255 character filename limit in most filesystems
      @@log_file ||= ::File.new("#{self.log_dir}/#{@logname}"[0..250] + '.log', 'w+')
    end

    # Accessor for @@log_dir
    def self.log_dir
      @@log_dir ||= "#{::Dir.home}/.chef/logs"
    end

    # Adds log header to @@log_file with the timestamp @stamp
    def self.add_log_header
      self.log_file.write("######################################################\n")
      self.log_file.write("# Logfile created on %s by knife-bs #\n" % @stamp)
      self.log_file.write("# cmd: `knife #{ARGV.join(" ")}` #\n")
      self.log_file.write("#       KnifeBs v. #{Knife::Bs::VERSION} #\n")
      self.log_file.write("######################################################\n")
    end

    def self.make_log_dir
      unless ::Dir.exist?(self.log_dir)
        ::FileUtils.mkdir_p(self.log_dir)
      end
    end
  end
end
