require 'chef/knife/bs_base'
require 'chef/knife/bs_server_create'
require 'chef/knife/ec2_server_create'
require 'parallel'
require 'fog'
require 'rubygems'


class Chef
  class Knife
    class BsRestore < Knife::BsServerCreate

      include Knife::BsBase

      deps do
        require 'chef/knife/bootstrap'
        Chef::Knife::Bootstrap.load_deps
        Chef::Knife::BsServerCreate.load_deps
      end

      banner "
############################################################################
----------------------------------------------------------------------------
knife bs restore VPC.SUBNET HOSTNAME(options)
----------------------------------------------------------------------------

Restore Process
Replace the EBS volumes of currently running nodes with pristine snapshots
created by the snapshot command. By default the snapshots are searched for
the corresponding subnet, unless you want to restore snapshots from a
different subnet.
Usage:
To restore the dev subnet:
    knife bs restore ame1.dev
To restore the dev subnet with production data:
    knife bs restore ame1.dev --from production
To restore the dev subnet with production and then delete the old detatched dev volumes :
    knife bs restore ame1.dev --from production --delete
############################################################################
"
      option :only_config,
             :long => '--dryrun',
             :description => 'Print config and exit'

      option :from,
             :short => '-f SUBNET',
             :long => '--from SUBNET',
             :description => 'Restore snapshots from given subnet.'

      option :delete_old_volumes,
             :long => '--delete',
             :description => 'Delete old volumes after restoring from snapshots.'

      option :quit_at,
             :short => '-q STAGE',
             :long => '--quit STAGE',
             :description => 'Quit after x number of stages',
             :default => 100

      option :force_detach,
             :long => '--force',
             :description => "Don't shutdown the server, just force detach the volume."

      option :matching_ami,
             :long => '--match',
             :description => "Shutdown the servers and reinstanciate with the same AMI. By default the latest AMI is used."

      option :from_version,
             :long => '--version VERSION',
             :description => 'Restore a specific version of the snapshots.'

      def run
        #
        # Put Fog into mock mode if --dry_run
        #
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end
        $stdout.sync = true

        if not [1,2].include?(name_args.size)
          show_usage
          exit 1
        end

        config[:verbosity] = 2 if config[:only_config]
        build_config(name_args)
        exit 1 if config[:only_config]

        servers = []
        spot_servers = []
        permanent_servers = []
        associations = {}

        # If from is not specified then, by default restore from the given subnet.
        if config[:from].nil?
          config[:from] = name_args.first.split('.').last
        end
        puts "\n\nRestoring data from #{config[:from].capitalize}\n\n"
        suffix = "." + "#{config[:vpc]}" + "." + "#{config[:domain]}"

        filters = []
        #
        # Get the Servers
        #
        if name_args.size == 1
          # Restore the entire cluster
          filters << "ms101"
          filters << "rs*"
        elsif name_args.size == 2
          # Restore only the selective servers
          filters << name_args.last
        else
          show_usage
          exit 1
        end
        # Find running servers
        filters.each do |filter|
          puts "Locating server with filter: #{filter}"
          servers += get_servers([name_args.first,filter])
        end
        servers.flatten
        servers.each do |x|
          if x.lifecycle == 'spot'
            spot_servers << x
          else
            permanent_servers << x
          end
        end

        puts "\nTotal Server:  #{servers.length}\nPermanent Servers: #{permanent_servers.length}\nSpot Servers: #{spot_servers.length}"
        exit 1 if config[:quit_at].to_i == 1

        #
        # Get Snapshots and Volumes
        #
        Parallel.map(servers, :in_threads => config[:batch_size].to_i) do |server|
          begin
            # Get attached volume.
            puts "\nGetting Snapshot and Volume for #{server.tags['fqdn']}"
            associations[server.tags['fqdn']] = {}
            associations[server.tags['fqdn']]['server'] = server
            associations[server.tags['fqdn']]['old_volume'] = server.volumes.select {|x| x.device == '/dev/sdf'}.first
            associations[server.tags['fqdn']]['snapshot'] = connection.snapshots.all('tag-value' => server.tags['fqdn'].gsub(config[:subnet], config[:from])).sort_by {|x| x.tags['created']}.last
          rescue SystemExit, Exception=>e
            ui.warn("#{e.message}\nCaught exception while trying to find snapshot/volume for server: #{server.tags['Name']}")
          end
        end
        exit 1 if config[:quit_at].to_i == 2

        #
        # Create volumes from snapshots
        #
        Parallel.map(associations.keys(), :in_threads => config[:batch_size].to_i) do |fqdn|
          begin
            puts "\nCreating new volume from snapshot : #{associations[fqdn]['snapshot'].tags['Name']}"
            associations[fqdn]['new_volume'] = create_volume_from_snapshot(associations[fqdn]['snapshot'])
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to create volume from snapshot for :#{fqdn}")
          end
        end
        exit 1 if config[:quit_at].to_i == 3

        #
        # Wait for New Volumes to be ready
        #
        Parallel.map(associations.keys(), :in_threads => config[:batch_size].to_i) do |fqdn|
          begin
            print "\nWaiting for new volume #{associations[fqdn]['new_volume'].id} to be ready..."
            associations[fqdn]['new_volume'].wait_for {print '.'; ready?}
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to create volume from snapshot for :#{fqdn}")
          end
        end
        exit 1 if config[:quit_at].to_i == 4

        #
        # Create tags for new volumes
        #
        Parallel.map(associations.keys(), :in_threads => config[:batch_size].to_i) do |fqdn|
          begin
            puts "\nCreating tags for new volume : #{fqdn}"
            tags = {
              'Name' => fqdn,
              'bs-owner' => fqdn,
              'vol_from_snapshot' => config[:from],
              'subnet' => config[:subnet]
            }
            tags['device'] = associations[fqdn]['old_volume'].nil? ? "/dev/sdf" : associations[fqdn]['old_volume'].tags['device']
            create_tags(associations[fqdn]['new_volume'].id, tags)
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to create tags for new volume #{fqdn}")
          end
        end
        puts "\nSuccessfully created tags for all new volumes."
        exit 1 if config[:quit_at].to_i == 5

        #
        # Rename old volumes
        #
        Parallel.map(associations.keys(), :in_threads => config[:batch_size].to_i) do |fqdn|
          unless associations[fqdn]['old_volume'].nil?
            begin
              puts "\nRenaming old volume for : #{fqdn}"
              tags = {
                'Name' => associations[fqdn]['old_volume'].tags['Name'] + '-old'
              }
              create_tags(associations[fqdn]['old_volume'].id, tags)
            rescue SystemExit, Exception=>e
              ui.warn("\n#{e.message}\nCaught exception while trying to Rename volume : #{fqdn}")
            end
          end
        end
        puts "\nSuccessfully renamed all old volumes."
        exit 1 if config[:quit_at].to_i == 6

        # <<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<<= Everything changes here =>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

        #
        # Shutdown all the PERMANENT INSTANCES
        #
        Parallel.map(permanent_servers, :in_threads => config[:batch_size].to_i) do |server|
          begin
            print "\nShutting down instance : #{server.tags['fqdn']}."
            server.stop
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to Shutdown server: #{server.tags['fqdn']}")
          end
        end
        exit 1 if config[:quit_at].to_i == 7

        #
        # Create NEW INSTANCES to replace SPOT INSTANCES
        #
        if spot_servers.length > 0
          # Terminate all the spot instances
          Parallel.map(spot_servers, :in_threads => config[:batch_size].to_i) do |server|
            begin
              print "\nTerminating old spot instance : #{server.tags['fqdn']}."
              server.destroy
            rescue SystemExit, Exception=>e
              ui.warn("\n#{e.message}\nCaught exception while trying to Terminate old spot instance: #{server.tags['fqdn']}")
            end
          end
          sleep 20
          if config[:match]
            config[:ami] = spot_servers.first.image_id
          else
            config[:latest] = true
          end

          # Bring up the servers
          begin
            if same_type?(spot_servers)
              puts "\nAll Spot Servers are of the same type.\n\n"
              name_args.pop if name_args.size == 2
              name_args << spot_servers.first.tags['hosttype']
              config[:number_of_nodes] = spot_servers.length
              super
            else
              spot_servers.each do |server|
                  name_args.pop if name_args.size == 2
                  name_args << server.tags['hosttype']
                  super
              end
            end
          rescue SystemExit, Exception=>e
            ui.error("#{e.message}\nError bringing up servers.")
          end
        end
        exit 1 if config[:quit_at].to_i == 8

        #
        # PERMANENT SERVERS >> Detach old volumes
        #
        Parallel.map(permanent_servers, :in_threads => config[:batch_size].to_i) do |server|
          begin
            unless associations[server.tags['fqdn']]['old_volume'].nil?
              print "\nWaiting for #{server.tags['fqdn']} to stop..."
              server.wait_for(timeout=1200) {print '.';state == 'stopped'}
              print "\nDetaching old volume for : #{server.tags['fqdn']}.."
              connection.detach_volume(associations[server.tags['fqdn']]['old_volume'].id)
              associations[server.tags['fqdn']]['old_volume'].wait_for {print '.';state == 'available'}
            end
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to detach old volume #{associations[server.tags['fqdn']]}")
          end
        end
        exit 1 if config[:quit_at].to_i == 9

        #
        # PERMANENT SERVERS >> Attach new volumes
        #
        Parallel.map(permanent_servers, :in_threads => config[:batch_size].to_i) do |server|
          begin
            puts "\nAttaching new volume #{associations[server.tags['fqdn']]['new_volume'].tags['Name']} to #{server.tags['fqdn']}"
            attach_volume(associations[server.tags['fqdn']]['server'], associations[server.tags['fqdn']]['new_volume'].id, '/dev/sdf')
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to attach new volume #{associations[server.tags['fqdn']]['new_volume'].tags['Name']}")
          end
        end
        exit 1 if config[:quit_at].to_i == 10

        #
        # PERMANENT SERVERS >> Start the servers
        #

        Parallel.map(permanent_servers, :in_threads => config[:batch_size].to_i) do |server|
          begin
            print "\nStarting instance : #{server.tags['fqdn']}. Waiting..."
            server.start
            server.wait_for {print '.'; ready?}
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to start server: #{server.tags['fqdn']}")
          end
        end
        exit 1 if config[:quit_at].to_i == 11

        #
        # PERMANENT SERVERS >> Delete old volumes
        #
        if config[:delete_old_volumes]
          ui.confirm("Are you sure you want to delete #{old_volumes.length} volumes")
          Parallel.map(associations.keys(), :in_threads => config[:batch_size].to_i) do |fqdn|
            begin
              puts "\nDeleting old volume: #{associations[fqdn]['old_volume'].tags['Name']}"
              associations[fqdn]['old_volume'].destroy
            rescue SystemExit, Exception=>e
              ui.warn("\n#{e.message}\nCaught exception while trying to delete old volume : #{associations[fqdn]['old_volume'].tags['Name']}")
            end
          end
        end

        print_messages
        print_time_taken
        print "#{ui.color("\nDone!\n\n", :bold)}"
      end
    end
  end
end
