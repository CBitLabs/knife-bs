require 'chef/knife/bs_base'
require 'chef/knife/ec2_base'
require 'chef/knife/ec2_server_create'

class Chef
  class Knife
    ## REVIEW why Ec2ServerCreate?
    class BsEbs < Knife::Ec2ServerCreate

      include Knife::BsBase

      deps do
        require 'fog'
        require 'readline'
        require 'chef/json_compat'
        require 'chef/knife/bootstrap'
        Chef::Knife::Bootstrap.load_deps
      end

      banner "
############################################################################
----------------------------------------------------------------------------
knife bs ebs VPC.SUBNET HOSTNAME (options)
----------------------------------------------------------------------------

Create new EBS volumes. Attach existing EBS volumes. Create temp volumes.
Usage:
To create and attach a new ebs volume
    knife bs ebs ame1.dev ms101 --perm 400
To attach an existing ebs volume to a running server
    knife bs ebs ame1.dev ms101 --attach
############################################################################
"
      option :ebs,
             :short => '-p SIZE',
             :long => '--perm SIZE',
             :description => 'The size of new Permanenet EBS volume '\
                             'to create in GB, for EBS-backed instances'

      option :attach,
             :long => '--attach',
             :description => 'To attach and EBS volume by searching the FQDN tag'

      option :temp,
             :short => '-t SIZE',
             :long => '--temp SIZE',
             :description => 'The size of TEMP EBS volume to create in GB.'

      option :vpc,
             :long => '--vpc VPC',
             :description => 'Which VPC to use. Default: ame1',
             :default => 'ame1'

      option :dry_run,
             :long => '--dry_run',
             :description => "Don't really run, just use mock calls"

      option :availability_zone,
             :short => '-Z ZONE',
             :long => '--availability-zone ZONE',
             :description => 'The Availability Zone',
             :proc => Proc.new { |key| Chef::Config[:knife][:availability_zone] = key }

      def run
        #
        # Put Fog into mock mode if --dry_run
        #
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end

        $stdout.sync = true
        unless name_args.size == 2
          ui.error('Please provide both arguments: VPC.SUBNET & HOSTNAME')
          show_usage
          exit 1
        end

        build_config(name_args)

        unless @bs.mixins[:volume] || @bs.mixins.volume.data[:ebs]
          ui.fatal("No volumes defined for this instance in the YAML")
          exit 1
        end

        ui.msg("Trying to locate server with tag-value : #{@bs.fqdn}")
        servers = connection.servers.all({"tag-value" => "#{@bs.fqdn}"})
        if servers.size == 0
          ui.fatal("Could not find server with fqdn tag : #{@bs.fqdn}")
          exit 1
        end

        puts "\nLocated server"
        server = servers.first

        #
        #Attach Existing EBS Volume
        #
        if @bs[:attach]
          begin
            #volume_id = get_volume_id( @bs.fqdn )
            # Get volume info from tags
            volumes = get_volumes(fqdn)
            @bs.mixins.volume.configure do |vmix|
              volumes.each do |v|
                # Attach the volume to the instance
                attach_volume(server, v.id, v.tags['device'])
                info = vmix.data.ebs[v.tags['device']]
                raise RuntimeError.new("Volume #{v.tags['device']}"\
                                       " not defined") unless info
                puts "Mount point : #{@bs.mixins.volume.get_mount(v.tags['device'])}"
              end
            end
            @bs.mixins.volume.ebs_init(server)
          rescue Exception => e
            ui.fatal("#{e.message}\nException attaching existing EBS volume. Exiting")
            exit 1
          end
        end
        ## GOOD/OK so far
        #
        #Create and attach a TEMP volume
        #
        # if @bs[:temp]
        #   begin
        #     ui.msg('Creating and attaching temp volume')
        #     ## REVIEW - hardcoded mount, device, filesystem
        #     tempvol = create_volume(server=server, size=config[:temp].to_i, device="/dev/sdc", volume_is_temp=true,fqdn=fqdn)
        #     @commands << 'mkfs.ext3 -q /dev/xvdc'
        #     @commands << 'mount /dev/xvdc /mnt'
        #     @commands << 'echo "/dev/xvdc /mnt auto noatime,nodiratime,defaults,nobootwait,comment=chef 0 2" >> /etc/fstab'
        #   rescue Exception => e
        #     ui.fatal("#{e.message}\nException while attaching temp volume. Exiting")
        #     exit 1
        #   end
        # end

        #
        #Create and attach a NEW EBS volume
        #
        if config[:ebs]
          begin
            ebsvol = create_volume(server, config[:ebs], false, config[:fqdn], false)
            device = ebsvol.device
            device_suffix = device[-1]
            ## REVIEW - everything is hardcoded here
            # Decide the directory where the device will be mounted
            if device == "/dev/sdf"
              directory = "ebs"
            else
              directory = "ebs" + device_suffix
            end

            @commands << 'partprobe'
            @commands << "mkfs.ext4 -b 4096  -q /dev/xvd#{device_suffix}"
            @commands << "e2label /dev/xvd#{device_suffix} #{directory}"
            @commands << "mkdir /#{directory}"
            @commands << "mount /dev/xvd#{device_suffix} /#{directory}"
            @commands << "echo \"LABEL=#{directory}	/#{directory} auto noatime,nodiratime,defaults,nobootwait,comment=knife-bs 0 2\" >> /etc/fstab"
          rescue Exception => e
            ui.fatal("#{e.message}\nException creating and attaching new volume. Exiting")
            exit 1
          end
        end

        #
        # Run commands,which format and mount volumes, and also run chef-client at the end
        ## REVIEW it does not appear to run chef-client at the end...
        #
        begin
          ui.msg(ui.color("Waiting for SSHD on server #{server.private_ip_address}",
                          :magenta))
          print '.' until tcp_test_ssh(server.private_ip_address, 22) { sleep 40 }
          puts "\nReady"
          run_commands(server, fqdn, @commands)
        rescue Exception => e
          ui.fatal("#{e.message}\nException running commands.")
        end

        # Done
        print_messages
        print "\n#{ui.color('Done!', :bold)}\n\n"
      end
      def build_config(name_args)
        config[:vpc] = name_args[0].split('.')[0]
        config[:subnet] = name_args[0].split('.')[1]
        config[:hostname] = name_args[1]
        base_config
        ## FUTURE multiple orgs
        @bs[:fqdn] = [@bs.hostname, @bs.subnet, @bs.vpc,
                      @bs.yaml.organizations.first.domain] * '.'
      end
    end
  end
end
