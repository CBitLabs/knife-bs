require 'chef/knife/bs_base'
require 'chef/knife/ec2_base'
require 'chef/knife/ec2_server_create'
require 'pry'

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
    knife bs ebs ame1.dev ms101 --create 400
To attach all existing ebs volumes to a running server
    knife bs ebs ame1.dev ms101 --attach
Attach using volume ID
    knife bs ebs ame1.dev ms101 --attach -i vol-XXXXXXXX
############################################################################
"
      ## Allow specifying by ID (look at Issa's updated ebs_delete) for
      ## Argument Inspiration

      option :create,
             :long => '--create SIZE',
             :description => 'The size of new permanent EBS volume to create'\
                             ' in GB, for EBS-backed instances'

      option :attach,
             :long => '--attach',
             :description => 'To attach and EBS volume by '\
                             'searching the FQDN tag or using the ID'

      option :vol_id,
             :short => '-i VOLUME_ID',
             :long => '--volume-id VOLUME_ID',
             :description => 'Volume id of the volume to attach. '\
                             'If specified, any other parameters '\
                             'are used to verify the correct device.'

      option :dry_run,
             :long => '--dry_run',
             :description => "Don't really run, just use mock calls"
             ## TODO - Move this configuration option into bs_base

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
        validate!

        # 2 Possible actions:
        # - attach existing volume (has to have the fqdn and device tags
        # and be defined inside the YAML)
        # - create/attach new volume (has to not already exist/be
        #   attached (look for matching tags)). If instance already has
        #   this volume

        unless @bs.mixins[:volume] || @bs.mixins.volume.data[:ebs]
          ui.fatal("No volumes defined for this instance in the YAML")
          exit 1
        end

        ui.msg("Trying to locate server with tag-value : #{@bs.fqdn}")
        servers = connection.servers.all({"tag-value" => "#{@bs.fqdn}"})
        if servers.size == 0
          ui.fatal("Could not find server with fqdn tag : #{@bs.fqdn}")
          exit 1
        elsif servers.size > 1
          ui.warn("Multiple servers with fqdn:#{@bs.fqdn} found")
        end

        # excon = connection.describe_instances({'instance-id'=>server.id})
        # attrib = excon.data[:body]['reservationSet'][0]['instancesSet'][0]
        # i = attrib['blockDeviceMapping'].index do |h|
        #   h['volumeId'] == volume.id
        # end
        # attributes = {
        #   "BlockDeviceMapping.#{i.to_s}.DeviceName"             => device,
        #   "BlockDeviceMapping.#{i.to_s}.Ebs.DeleteOnTermination"=> "true"
        # }
        # connection.modify_instance_attribute(server.id, attributes)

        puts "\nLocated server"
        server = servers.first
        #
        #Attach Existing EBS Volume
        #
        if @bs[:attach]
          begin
            #volume_id = get_volume_id( @bs.fqdn )
            # Get volume info from tags
            volumes = get_volumes(@bs.fqdn)
            @bs.mixins.volume.configure do |vmix|
              volumes.each do |v|
                (v.state == 'in-use' || v.server_id) &&
                  ui.warn("Volume #{v.id} already attached "\
                          "(state: #{v.state})") && next

                info = vmix.data.ebs[v.tags['device']]
                raise RuntimeError.new("Volume #{v.tags['device']} "\
                                       " not defined in YAML") unless info
                puts "Mount point : #{@bs.mixins.volume.get_mount(v.tags['device'])}"
                attach_volume(server, v.id, v.tags['device'])
                ## GOOD/OK so far
              end
            end
          rescue Exception => e
            ui.fatal("#{e.message}\nException attaching existing EBS volume. Exiting")
            exit 1
          end

        elsif @bs[:create]
          begin
            
          rescue Exception => e
            ui.fatal("#{e.message}\nException creating and attaching new volume. Exiting")
            exit 1
          end
        end

        #
        #Create and attach a NEW EBS volume
        #
        # if config[:ebs]
        #   begin
        #     ebsvol = create_volume(server, config[:ebs], false, config[:fqdn], false)
        #     device = ebsvol.device
        #     device_suffix = device[-1]
        #     ## REVIEW - everything is hardcoded here
        #     # Decide the directory where the device will be mounted
        #     if device == "/dev/sdf"
        #       directory = "ebs"
        #     else
        #       directory = "ebs" + device_suffix
        #     end

        #     @commands << 'partprobe'
        #     @commands << "mkfs.ext4 -b 4096  -q /dev/xvd#{device_suffix}"
        #     @commands << "e2label /dev/xvd#{device_suffix} #{directory}"
        #     @commands << "mkdir /#{directory}"
        #     @commands << "mount /dev/xvd#{device_suffix} /#{directory}"
        #     @commands << "echo \"LABEL=#{directory}	/#{directory} auto noatime,nodiratime,defaults,nobootwait,comment=knife-bs 0 2\" >> /etc/fstab"
        #   rescue Exception => e
        #     ui.fatal("#{e.message}\nException creating and attaching new volume. Exiting")
        #     exit 1
        #   end
        # end

        # #
        # # Run commands,which format and mount volumes, and also run chef-client at the end
        # ## REVIEW it does not appear to run chef-client at the end...
        # #
        # begin
        #   ui.msg(ui.color("Waiting for SSHD on server #{server.private_ip_address}",
        #                   :magenta))
        #   print '.' until tcp_test_ssh(server.private_ip_address, 22) { sleep 40 }
        #   puts "\nReady"
        #   run_commands(server, fqdn, @commands)
        # rescue Exception => e
        #   ui.fatal("#{e.message}\nException running commands.")
        # end

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
                      @bs.yaml.organizations.Bitsight.domain] * '.'
      end

      def validate!
        # There must be volumes defined in the YAML

        # Requested volumes must exist in YAMl, whether attaching or
        # creating

        # If attaching volume, ensure that the block mapping doesn't
        # already include it
      end
    end
  end
end
