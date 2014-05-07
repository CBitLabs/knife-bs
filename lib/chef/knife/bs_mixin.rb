require 'erubis'
require 'yaml'
require 'kwalify'
require 'chef/bs_utils/bs_logging'
require 'knife-bs/monkey_patches/ui'
require 'awesome_print'
require 'net/scp'
require 'knife-bs/errors'
require 'chef/knife/bs_config'
require 'chef/knife/bs_util'

class Chef
  class Knife
    module BsMixin
      include ::BsUtils::BsLogging
      # Mixins are used to directly interact with nodes over ssh/scp
      # Typically bash scripts are used but any kind of script will do,
      # provided the interpreter is declared at the head of the
      # script. The alternative purpose is to store data that can be
      # inherited down the YAML configuration tree

      attr_accessor :mixconf
      attr_accessor :validator
      attr_accessor :data
      attr_accessor :bs
      attr_accessor :ui
      attr_accessor :user_data_validator

      @@included_mixins = Set.new
      @@last_included = nil
      def self.included(includer)
        @@included_mixins << includer
        @@last_included = includer
      end

      def self.ui
        @ui ||= Chef::Knife::UI.new(STDOUT, STDERR, STDIN, {})
      end

      # Used to keep track of loading mixins
      def self.last_included
        @@last_included
      end

      def self.included_mixins
        @@included_mixins
      end

      def initialize(bsconfig, name, data, path=nil)
        @ui = Chef::Knife::UI.new(STDOUT, STDERR, STDIN, {})
        @bs = bsconfig
        @data = data
        @name = name
        # If path is not provided, this is a qualified mixin with no
        # actionable files
        return unless path
        @basepath = path
        load_config
        load_user_data_validator
        validate
        ## REVIEW script directory
        @@script_dir = File.join( Dir.mktmpdir( 'bs' ),
                                  'knife-bs',
                                  'mixin',
                                  @name)

        FileUtils.mkdir_p(@@script_dir) unless Dir.exists?(@@script_dir)

        # Initialize a runlist
        # Each one is a map of servers -> list of scripts to run
        @@execlist ||= { 'before_chef' => {},
                         'after_chef'  => {} }
      end

      def configure(&block)
        yield self if block_given?
      end

      def validate
        # Run user-data validation against schema
        errors = []
        begin
          to_validate = @data.is_a?(SubConfig) ? @data.to_h : @data
          errors = @user_data_validator.validate(to_validate)
        rescue Kwalify::KwalifyError => e
          ui.warn("Unable to validate user data"\
                  " for mixin #{@name}"\
                  "#{e.backtrace.join('\n')}")
        ensure
          unless errors.empty?
            ui.fatal("Mixin configuration invalid:\n")
            errors.each do |e|
              ui.fatal("#{e.linenum}:#{e.column} [#{e.path}] #{e.message}")
            end
            exit 1
          end
          errors
        end
      end

      def self.runlist
        @@runlist
      end

      def self.instlist
        @@instlist
      end

      def load_user_data_validator
        begin
          schema = YAML.load_file(File.join(@basepath, 'schema.yml'))
          @user_data_validator = UserDataValidator.new(schema)
        rescue Exception => e
          ui.msg(ui.color("Unable to load schema\n#{e}", :yellow))
        end
      end

      def load_config
        begin
          @mixconf ||= YAML.load_file(File.join(@basepath, 'mixin.yml'))
          @mix     ||= SubConfig.new(@mixconf)
        rescue Exception => e
          ui.msg(ui.color("Unable to load mixin.yml\n#{e}", :yellow))
        end
      end

      def load_template(name)
        begin
          File.read(File.join(@basepath, 'templates', name))
        rescue Exception => e
          ui.msg(ui.color("Unable to load template #{name} from "\
                          "#{File.join(@basepath, 'templates')}\n"\
                          "#{e.message}", :yellow))
        end
      end

      ## REVIEW unused
      def validate_config
        @schema ||=
          begin
            YAML.load_file(File.expand_path(
                            File.join(__FILE__, '../../bs-mixin-schema.yaml')))
          end
        @validator ||= Kwalify::Validator.new(schema)
        @validator.validate(@mixconf)
      end

      def cook(template, server=nil, overwrite=false)
        execonf = @mix.mixin.files[template] || {}
        outfile = execonf['outfile'] || template
        localdir = server.nil? ? @@script_dir : File.join(@@script_dir, server.id)
        localfile = File.join(localdir, outfile)
        FileUtils.mkdir_p(localdir) unless Dir.exists?(localdir)

        # If it doesn't exist, ignore overwrite arg
        if (not File.file?(localfile)) || overwrite
          File.open(localfile, 'w') do |f|
            eruby = Erubis::Eruby.new(load_template(template))
            f.write(eruby.result(binding))
            f.chmod(0755)
          end
        end

        # Succeeded, return localfile
        localfile
      end

      # Block gets passed along to the execlist
      def action(action, server, template, &block)
        ui.msg(ui.color("ACTION (#{@name})::#{action} --> #{template}", :cyan))
        execonf = @mix.mixin.files[template] || {}
        localfile = cook(template, server, overwrite=true)
        run_at = execonf['run-at'] || 'before_chef'
        # Schedule action
        @@execlist[run_at][server.id] ||= []
        @@execlist[run_at][server.id] << [action, execonf, localfile, block]
        [action, execonf, localfile, block]
      end

      def self.exec(stage, ssh, fqdn, server)
        return unless @@execlist[stage][server.id]
        @@execlist[stage][server.id].each do |action, execonf, localfile, block|
          action_args = []
          case action
          when 'install'
            self.install_script(localfile, execonf,
                                ssh, fqdn, server, &block)
          when 'run'
            self.run_script(localfile, execonf,
                            ssh, fqdn, server, &block)
          end
        end
      end

      def self.run_command(ssh, cmd)
        ssh.name_args[1] = cmd
        begin
          ui.msg(ui.color("COMMAND [#{cmd}]", :green))
          exit_status = ssh.run
        rescue SystemExit, Exception=>e
          ui.err("Command failed: #{e.message}")
          exit 1
        end
      end

      def self.install_script(localfile, execonf, ssh, fqdn, server, &block)
        begin
          # Use "install" command with parameters from execonf
          remote_path = execonf['dir']   || nil
          mode        = execonf['mode']  || '755'
          owner       = execonf['owner'] || 'root'
          group       = execonf['group'] || 'root'

          # Upload to a temporary location
          temporary_loc = '/home/ubuntu/'
          print ui.color("SCP #{File.basename(localfile)} --> "\
                         "#{ssh.config[:ssh_user]}@#{fqdn}:"\
                         "#{temporary_loc}"\
                         " ", #"\nMore info:\n#{ssh.config.inspect}\n ",
                         :magenta)
          Net::SCP.upload!(server.private_ip_address,
                           ssh.config[:ssh_user],
                           localfile,
                           temporary_loc,
                           ssh: {
                             password:  ssh.config[:ssh_password],
                             port:      ssh.config[:ssh_port],
                             keys:      [ssh.config[:identity_file]],
                           }) {print '.'}; puts "OK"

          if remote_path
            install_cmd = ['sudo install',
                           '-g', owner,
                           '-m', mode,
                           '-o', owner,
                           '-t', remote_path,
                           File.join(temporary_loc, File.basename(localfile))
                          ] * ' '
            ssh.name_args = server.private_ip_address, install_cmd
            ui.msg(ui.color("INSTALL [#{install_cmd}]", :yellow))
            exit_status = ssh.run
            raise BootstrapError.new unless exit_status == 0
          end

          execonf[:installed]          ||= {}
          execonf[:installed][server.id] =
            File.join((remote_path || temporary_loc), File.basename(localfile))

          yield ssh, execonf if block_given?
        rescue SystemExit, Exception=>e
          ui.error("Errored out installing #{File.basename(localfile)} to #{fqdn}"\
                   "\n#{e}")
        end
        ui.msg(ui.color("INSTALLED to #{execonf[:installed][server.id]}", :red))
        execonf[:installed][server.id]
      end

      def self.run_script(localfile, execonf, ssh, fqdn, server, &block)
        # If the file hasn't been installed, do so first
        execonf['run-as']            ||= 'root'
        execonf[:installed]          ||= {}
        execonf[:installed][server.id] =
          install_script(localfile, execonf, ssh, fqdn, server)
        command = "sudo -u#{execonf['run-as']} \"#{execonf[:installed][server.id]}\""
        ssh.name_args = [server.private_ip_address, command]
        begin
          ui.msg(ui.color("COMMAND [#{command}]", :green))
          exit_status = ssh.run
          raise BootstrapError.new unless exit_status == 0
          yield ssh, execonf if block_given?
        rescue Exception=>e
          ui.warn("SSH: Exit-Status =/= 0 for Command: #{command} on Server: #{fqdn}")
        end
      end

      class QualifiedMixin
        # Mixin that is just data
        include ::Chef::Knife::BsMixin
      end

      # Can be modified by the including class
      class UserDataValidator < Kwalify::Validator
        # def validate_hook(value, rule, path, errors)
        #   puts path
        # end
      end
    end
  end
end
