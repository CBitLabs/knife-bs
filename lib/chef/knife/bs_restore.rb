require 'chef/knife/bs_base'
require 'chef/knife/bs_server_create'
require 'chef/knife/ec2_server_create'
require 'parallel'
require 'fog'
require 'rubygems'


class Chef
  class Knife
    class BsRestore < Knife::BsServerCreate

      ## TODO
      ## Test with multiple EBS volumes on one node
      ## Test with multiple nodes (one EBS)
      ## Test with multiple nodes (multiple EBS)
      ## Test with multiple snapshots available
      include Knife::BsBase

      deps do
        require 'chef/knife/bootstrap'
        Chef::Knife::Bootstrap.load_deps
        Chef::Knife::BsServerCreate.load_deps
      end

      banner "
############################################################################
----------------------------------------------------------------------------
knife bs restore VPC.SUBNET (HOSTNAME|STACK) (options)
----------------------------------------------------------------------------

Restore Process
Replace the EBS volumes of currently running nodes with pristine snapshots
created by the snapshot command. By default the snapshots are searched for
the corresponding subnet, unless you want to restore snapshots from a
different subnet.
Usage:
To restore the dev subnet cluster:
    knife bs restore ame1.dev cluster --stack
To restore the dev subnet with production data:
    knife bs restore ame1.dev cluster --stack --from prd1
To restore the dev subnet with production and delete the old dev volumes :
    knife bs restore ame1.dev cluster --stack --from prd1 --delete
To restore an ms node in the dev subnet with prod data:
    knife bs restore ame1.dev ms101 --from prd1
There are 11 phases that you can --quit <STAGE> after:
1: Getting servers
2: Locate snapshots/volumes
3: Create new volumes from snapshots
4: Wait for new volumes to be ready
5: Tag the new volumes
6: Rename the old volumes
7: Shut down on-demand instances
8: Terminate spot instances

############################################################################
"
      option :only_config,
             :long => '--dryrun',
             :boolean => true,
             :default => false,
             :description => 'Print config and exit'

      option :from,
             :short => '-f SUBNET',
             :long => '--from SUBNET',
             :description => 'Restore snapshots from given subnet.'

      option :delete_old_volumes,
             :long => '--delete',
             :boolean => true,
             :default => false,
             :description => 'Delete old volumes after restoring from '\
                             'snapshots.'

      option :rename_old_volumes,
             :long => '--rename',
             :boolean => true,
             :default => true,
             :description => 'Rename old volumes after restoring from '\
                             'snapshots.'

      option :quit_at,
             :short => '-q STAGE',
             :long => '--quit STAGE',
             :description => 'Quit after x number of stages',
             :default => 100

      option :force_detach,
             :long => '--force',
             :boolean => true,
             :description => 'Do not shutdown the server, '\
                             'just force detach the volume.'

      ## REVIEW
      option :matching_ami,
             :long => '--match',
             :boolean => true,
             :description => 'Shutdown the servers and re-instantiate with '\
                             'the same AMI. By default the latest AMI is used.'

      option :from_version,
             :long => '--version VERSION',
             :description => 'Restore a specific version of the snapshots.'

      option :stack_interpret,
             :long => '--stack',
             :boolean => true,
             :description => 'Interpret second arg as stack, not hostname'

      def run
        #
        # Put Fog into mock mode if --dry_run
        #
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end
        $stdout.sync = true

        build_config(name_args)
        exit 1 if config[:only_config]

        restore
      end

      def build_config(name_args)
        if not [1,2].include?(name_args.size)
          show_usage
          exit 1
        end

        name_args.reverse!
        config[:vpc], config[:subnet] = name_args.pop.split('.')
        base_config
        ! name_args.size.zero? && @bs[:stack_interpret] ?
          @bs[:stack]  = name_args.pop :
          @bs[:filter] = name_args.pop

        # If from is not specified then, by default restore from given subnet.
        @bs[:from] ||= @bs.subnet
        config[:verbosity] = 2 if config[:only_config]
      end

      def find_servers(vpc = @bs.vpc)
        if @bs[:stack]
          stack_def = @bs.get_stack
          stack_def.profiles.map do |p,info|
            profile = @bs.get_profile(p)
            pos = profile.hostname =~ /\%/
            hostname = pos ? profile.hostname[0...pos] + '*' : profile.hostname
            fqdn = [hostname, @bs.subnet,
                    vpc,      @bs.domain]*'.'
            get_servers(@bs.subnet, vpc, hostname)
          end.flatten
        else
          get_servers(@bs.subnet, vpc, @bs.filter)
        end
      end

      def restore
        ui.msg("\nRestoring data from #{config[:from]}\n")

        associations = SubConfig.new({})
        servers = find_servers
        @bs[:batch_size] = servers.size
        spot_servers = servers.select {|x| x.lifecycle == 'spot'}
        permanent_servers = servers.reject do |k,_|
          spot_servers.include? k
        end

        puts "\nTotal servers: #{servers.size}\nPermanent Servers: "\
             "#{permanent_servers.size}\nSpot Servers: #{spot_servers.size}"
        exit 1 if @bs.quit_at.to_i == 1

        #
        # Get Snapshots and Volumes
        #
        Parallel.map(servers, :in_threads =>
                              @bs.batch_size.to_i) do |server|
          begin
            # Get attached volumes
            puts "\nGetting Snapshots and Volumes for #{server.tags['fqdn']}"
            associations[server.tags['fqdn']] = {}
            associations[server.tags['fqdn']]['server'] = server

            # Get the snapshots for the 'from' subnet
            snapshots = connection.snapshots.all(
              'tag-value' => server.tags['fqdn'].gsub(@bs.subnet,
                                                      @bs.from)).
                        sort_by {|x| x.tags['created']}
            # We now have all of the snapshots for this fqdn ever made,
            # need to reject the ones that are part of an earlier
            # snapshot
            latest_epoch = snapshots.last.tags['created']
            associations[server.tags['fqdn']]['snapshots'] =
              snapshots.select {|ss| ss.tags['created'] == latest_epoch}
          rescue SystemExit, Exception=>e
            ui.warn("#{e.message}\nCaught exception while trying to find "\
                    "snapshot/volume for server: #{server.tags['Name']}")
          end
        end
        exit 1 if @bs.quit_at.to_i == 2

        #
        # Create volumes from snapshots
        #
        Parallel.map(associations.keys(), :in_threads =>
                                          @bs.batch_size.to_i) do |fqdn|
          associations[fqdn]['new_volumes'] = {}
          begin
            associations[fqdn]['snapshots'].each do |ss|
              associations[fqdn]['new_volumes'][ss.tags['device']] =
                create_volume_from_snapshot(ss)
            end
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying"\
                    " to create volume from snapshot for :#{fqdn}")
          end
        end
        exit 1 if @bs.quit_at.to_i == 3

        #
        # Wait for New Volumes to be ready
        #
        all_new_volumes = associations.collect do |_,info|
          info.new_volumes.hash.values
        end.flatten
        Parallel.map(all_new_volumes, :in_threads =>
                                      all_new_volumes.size) do |volume|
          begin
            print "\nWaiting for new volume #{volume.id} to be ready..."
            volume.wait_for {print '.'; ready?}
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying"\
                    " to create volume from snapshot"\
                    " for: #{volume.id}")
          end
        end
        exit 1 if @bs.quit_at.to_i == 4

        #
        # Create tags for new volumes
        #
        Parallel.map(associations.keys, :in_threads =>
                                        @bs.batch_size.to_i) do |fqdn|
          begin
            associations[fqdn]['new_volumes'].each do |device,volume|
              ui.msg("\nCreating tags for new volume : #{volume.id}")
              tags = {
                'Name'              => fqdn,
                'bs-owner'          => fqdn,
                'vol_from_snapshot' => @bs.from,
                'subnet'            => @bs.subnet,
                'vpc'               => @bs.vpc,
                'device'            => device
              }
              create_tags(volume.id, tags)
            end
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying"\
                    " to create tags for new volume #{fqdn}")
          end
        end
        puts "\nSuccessfully created tags for all new volumes."
        exit 1 if @bs.quit_at.to_i == 5


        #
        # Rename old volumes
        #
        Parallel.map(associations.keys(), :in_threads =>
                                          @bs.batch_size.to_i) do |fqdn|
          begin
            associations[fqdn]['snapshots'].each do |ss|
              vol_id = ss.tags['volume-id']
              ui.msg("\nRenaming old volume #{vol_id}")
              vol = connection.volumes.get(vol_id)
              # Append -old to the volume which was restored
              tags = {
                'Name' => vol.tags['Name'] + '-old'
              }
              create_tags(vol_id, tags)
            end
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying "\
                    "to rename volume : #{fqdn}")
          end
        end
        puts "\nSuccessfully renamed all old volumes."
        exit 1 if @bs.quit_at.to_i == 6

        # <<<<<<<<<<<<= Everything changes here =>>>>>>>>>>>>
        #
        # Shutdown all the PERMANENT INSTANCES
        #
        Parallel.map(permanent_servers, :in_threads =>
                                        @bs.batch_size.to_i) do |server|
          begin
            print "\nShutting down instance : #{server.tags['fqdn']}."
            server.stop
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying"\
                    " to Shutdown server: #{server.tags['fqdn']}")
          end
        end
        exit 1 if @bs.quit_at.to_i == 7

        ## FUTURE replace all of this with cluster create so we can
        ## Bring the entire cluster down/up

        #
        # Create NEW INSTANCES to replace SPOT INSTANCES
        #
        if spot_servers.length > 0
          # Terminate all the spot instances
          Parallel.map(spot_servers, :in_threads =>
                                     @bs.batch_size.to_i) do |server|
            begin
              print "\nTerminating old spot instance : #{server.tags['fqdn']}."
              server.destroy
            rescue SystemExit, Exception=>e
              ui.warn("\n#{e.message}\nCaught exception while trying"\
                      " to Terminate old spot instance:"\
                      " #{server.tags['fqdn']}")
            end
          end
          binding.pry
          ## GOOD/OK/REVIEWED until here
          ## REVIEW sleeping? See if there is a wait_for you can do
          sleep 20
          if @bs[:match]
            ## REVIEW using just the first spot server to get AMI
            @bs[:ami] = spot_servers.first.image_id
          else
            @bs[:latest] = true
          end

          # Bring up the servers
          begin
            if same_type?(spot_servers)
              puts "\nAll Spot Servers are of the same type.\n\n"
              name_args.pop if name_args.size == 2
              name_args << spot_servers.first.tags['hosttype']
              @bs[:number_of_nodes] = spot_servers.length
              ## REVIEW call to super here for spinning up instances.
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
        exit 1 if @bs.quit_at.to_i == 8

        #
        # PERMANENT SERVERS >> Detach old volumes
        #
        Parallel.map(permanent_servers, :in_threads =>
                                        @bs.batch_size.to_i) do |server|
          begin
            unless associations[server.tags['fqdn']]['old_volume'].nil?
              print "\nWaiting for #{server.tags['fqdn']} to stop..."
              server.wait_for(timeout=1200) {print '.';state == 'stopped'}
              print "\nDetaching old volume for : #{server.tags['fqdn']}.."
              connection.detach_volume(
                associations[server.tags['fqdn']]['old_volume'].id
              )
              associations[server.tags['fqdn']]['old_volume'].wait_for do
                print '.'
                state == 'available'
              end
            end
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to detach old volume #{associations[server.tags['fqdn']]}")
          end
        end
        exit 1 if @bs.quit_at.to_i == 9

        #
        # PERMANENT SERVERS >> Attach new volumes
        #
        Parallel.map(permanent_servers, :in_threads => @bs.batch_size.to_i) do |server|
          begin
            puts "\nAttaching new volume #{associations[server.tags['fqdn']]['new_volume'].tags['Name']} to #{server.tags['fqdn']}"
            attach_volume(associations[server.tags['fqdn']]['server'], associations[server.tags['fqdn']]['new_volume'].id, '/dev/sdf')
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to attach new volume #{associations[server.tags['fqdn']]['new_volume'].tags['Name']}")
          end
        end
        exit 1 if @bs.quit_at.to_i == 10

        #
        # PERMANENT SERVERS >> Start the servers
        #

        Parallel.map(permanent_servers, :in_threads => @bs.batch_size.to_i) do |server|
          begin
            print "\nStarting instance : #{server.tags['fqdn']}. Waiting..."
            server.start
            server.wait_for {print '.'; ready?}
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to start server: #{server.tags['fqdn']}")
          end
        end
        exit 1 if @bs.quit_at.to_i == 11

        #
        # PERMANENT SERVERS >> Delete old volumes
        #
        if config[:delete_old_volumes]
          ui.confirm("Are you sure you want to delete #{old_volumes.length} volumes")
          Parallel.map(associations.keys(), :in_threads => @bs.batch_size.to_i) do |fqdn|
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
