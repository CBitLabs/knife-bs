require 'chef/knife/bs_base'
require 'chef/knife/ec2_base'
require 'chef/knife/ec2_server_create'

class Chef
  class Knife
    class BsEbsDelete < Knife::Ec2ServerCreate

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
knife bs ebs delete [-i VOLUME-ID / VPC.SUBNET HOSTNAME] (options)
----------------------------------------------------------------------------

Delete an EBS volume for a node. Parameter can be either a volume id, or
hostname.
The host must either be running or terminated in order to detach volumes. 
Usage:
To delete using volume id:
    knife bs ebs delete -i vol-3912sk21
To delete all ebs volumes tagged for a terminated server:
    knife bs ebs delete ame1.dev ms101
To detach and delete an ebs volume for a running server:
    knife bs ebs delete ame1.dev ms101 --devices sdc,sdg
############################################################################
"

      option :devices,
             :long => '--devices DEVICES',
             :description => 'Comma separated list of block device mappings to delete'

      option :vol_id,
             :short => '-i VOLUME_ID',
             :long => '--volume-id VOLUME_ID',
             :description => 'Volume id of the volume to delete. '\
                             'If specified, any other parameters are '\
                             'used to verify the correct device.'

      option :detach,
             :long => '--detach',
             :description => 'Must pass this option to allow detaching from running nodes'

      option :force_detach,
             :long => '--force-detach',
             :description => 'Force detachment. This can cause corruption in the instance. Muste be called with detach, otherwise ignored.'

      option :dry_run,
             :long => '--dry_run',
             :description => 'Do not really run, just use mock calls'

      option :availability_zone,
             :short => '-Z ZONE',
             :long => '--availability-zone ZONE',
             :description => 'The Availability Zone',
             :proc => Proc.new { |key| Chef::Config[:knife][:availability_zone] = key }

      def run
        $stdout.sync = true
        # Put Fog into mock mode if --dry_run
        #
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end

        build_config(name_args)
        if @bs[:vol_id]
          delete_volume_id
        else
          ui.msg("\nTrying to locate server with tag-value : #{@bs.fqdn}")
          servers = connection.servers.all({"tag-value" => "#{@bs.fqdn}"})
          if servers.size == 0
            ui.msg("\nNo servers found, checking for unattached volumes.")
            delete_volumes_for_fqdn
          else
            delete_servers servers
          end
        end

        # Done
        ui.msg(ui.color('Done!', :bold))
      end

      def build_config(name_args)
        #
        # Check the input
        #
        if name_args.size == 2
          name_args.reverse!
          config[:vpc], config[:subnet] = name_args.pop.split('.')
          config[:hostname] = name_args.pop
          base_config
          @bs[:fqdn] = [@bs[:hostname],
                        @bs[:subnet],
                        @bs[:vpc],
                        @bs[:domain]] * '.'

          if config[:subnet] =~ /\*/
            ui.error('Wildcards are specifically prohibited in subnets.')
            show_usage
            exit 1
          end

          if config[:hostname].empty? || config[:hostname] == '*'
            ui.error('Must provide at least one character for hostname.')
            show_usage
            exit 1
          end

        elsif name_args.size != 0
          ui.error('Please provide either (--volume-id VOLUME-ID) and/or '\
                   'both (VPC.SUBNET & HOSTNAME)')
          show_usage
          exit 1
        elsif not config[:vol_id]
          show_usage
          exit 1
        else
          base_config
        end
      end

      def delete_volume_id
        vol = connection.volumes.get(@bs.vol_id)
        unless vol
          ui.error("\nCannot find volume #{@bs.vol_id}")
          exit 1
        end

        check_volume_name(vol)
        check_volume_devices(vol)

        ui.msg("\nDeleting volume : #{@bs.vol_id}")
        delete_volumes([vol])
      end

      def delete_volumes_for_fqdn
        vols = get_volumes(@bs.fqdn)
        if vols.size == 0
          ui.fatal("\nCan not find any volumes "\
                   "belonging to server: #{@bs.fqdn}")
          exit 0
        end
        volumes = vols.select do |vol|
          check_volume_devices(vol, false)
        end
        if volumes.size == 0
          ui.fatal("\nCan not find any volumes "\
                   "for server #{@bs.fqdn} "\
                   "mounted on #{@bs.devices}")
          exit 0
        end
        delete_volumes(volumes)
      end

      def delete_servers( servers )
        vols = []
        servers.each do |server|
          ui.msg("\nLocated #{server.state} server "\
                 "#{server.id} #{@bs.fqdn}")
        end

        # Begin deletion process:
        servers.each do |server|
          server.block_device_mapping.each do |device|
            unless device['deleteOnTermination']
              vol = connection.volumes.get(device['volumeId'])
              vols << vol if check_volume_devices(vol, false)
            end
          end

          if server.state == 'terminated'
            #Then we can have some unattached volumes floating about
            if server.tags.key?('fqdn')
              volumes = get_volumes(server.tags['fqdn'])
              volumes.each do |vol|
                vols << vol if check_volume_devices(vol, false)
              end
            end
          end
        end

        delete_volumes(vols)
      end

      def delete_volumes( volumes )
        volumes.uniq! {|v| v.id}
        # Detach all the volumes first
        # * Don't delete anything till they can all be safely detached
        volumes.each do |volume|
          begin
            unless volume.state =='available'
              if @bs[:detach]
                name = volume_name(volume)
                options = {}
                if @bs[:force_detach]
                  options['Force'] = true
                end
                ui.confirm("Detach volume #{volume.id} #{volume_name(volume)}")
                connection.detach_volume("#{volume.id}", options)
                ui.msg("\nWaiting for volume #{volume.id} #{name} to detach")
                volume.wait_for { print '.'; state=='available' }
                puts "\n"
              else
                ui.error("\nVolume #{volume.id} is not available, "\
                         "and --detach option was not passed. "\
                         "You must pass --detach to remove volumes "\
                         "from attached systems. This is a safety check")
                exit 1
              end
            end
          rescue Exception=>e
            ui.error("#{e.message}\nException detaching volume #{volume.id}")
            exit 1
          end
        end

        #Now delete all the volumes
        volumes.each do |volume|
          begin
            ui.confirm("DELETE volume #{volume.id} #{volume_name(volume)}")
            ui.msg("\nDeleting Volume #{volume.id} #{volume_name(volume)}")
            connection.delete_volume("#{volume.id}")
            ui.msg(ui.color("Volume #{volume.id} #{volume_name(volume)} "\
                            "Deleted", :bold))
          rescue Exception=>e
            ui.error("#{e.message}\nException deleting volume "\
                     "#{volume.id} #{volume_name(volume)}")
            exit 1
          end
        end
      end

      def volume_name( volume )
        name = ''
        if volume.tags.key?('Name')
           name += volume.tags['Name']
        end
        if volume.tags.key?('device')
           name += " mounted on #{volume.tags['device']}"
        end
        name
      end

      def check_volume_devices( volume, fatal=true )
        # If devices was provided, make sure the volume tags matches
        if @bs[:devices]
          unless volume.tags.key?('device')
            if fatal
              ui.error('The volume id has no devices tag to check. '\
                       'To delete the volume anyway, call again '\
                       'without specifying devices.')
              show_usage
              exit 1
            else
              return false
            end
          end
          unless @bs.devices.split(',').include?(volume.tags['device'])
            if fatal
              ui.error('The volume id does not match the device. '\
                       'To delete the volume anyway, call again '\
                       'without specifying devices.')
              show_usage
              exit 1
            else
              return false
            end
          end
        end
        return true
      end

      def check_volume_name( volume )
        #if fqdn was provided, make sure the volume tags matches
        if @bs[:fqdn]
          unless volume.tags.key?('Name')
            ui.error('The volume id has no Name tag to check fqdn. '\
                     'To delete the volume anyway, call again '\
                     'without specifying host.')
            show_usage
            exit 1
          end
          unless @bs.fqdn == volume.tags['Name']
            ui.error('The volume id passed does not match the fqdn. '\
                     'To delete the volume anyway, call again '\
                     'without specifying host.')
            show_usage
            exit 1
          end
        end
      end
    end
  end
end
