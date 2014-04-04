require 'chef/knife/bs_base'
require 'knife-bs/monkey_patches/bs_array'
require 'parallel'
require 'fog'
require 'time'

class Chef
  class Knife
    class BsSnapshot < Knife::Ec2ServerCreate

      include Knife::BsBase
      banner "
############################################################################
----------------------------------------------------------------------------
knife bs snapshot VPC.SUBNET (HOSTNAME|STACK) (options)
----------------------------------------------------------------------------

Snapshot the attached EBS volumes of a list of servers.
You can snapshot an entire stack (i.e. hadoop cluster) or just a specific
server.

Usage:
To snapshot the entire dev cluster:
    knife bs snapshot ame1.dev cluster --stack
To snapshot just a single server, say ms101.dev
    knife bs snapshot ame1.dev ms101
To snapshot servers based on a given name wildcard
    knife bs snapshot ame1.dev cm*
    knife bs snapshot ame1.dev rs*
############################################################################
"
      option :only_config,
             :long => '--dryrun',
             :description => 'Print config and exit'

      option :progress,
             :short => '-p',
             :long => '--progress',
             :description => 'Print progress of the snapshot'

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
        validate!
        exit 1 if config[:only_config]

        snapshot
      end

      def build_config(name_args)
        unless name_args.size > 1
          show_usage
          exit 1
        end
        name_args.reverse!
        config[:vpc], config[:subnet] = name_args.pop.split('.')
        config[:stack_interpret] ?
          config[:stack] = name_args.pop :
          config[:filter] = name_args.pop

        config[:verbosity] = 2 if config[:only_config]
        config[:verbosity] = -1 if config[:progress]

        base_config
        show_progress(name_args) if @bs[:progress]
      end

      def snapshot
        volumes = []
        servers = []
        snapshots = []

        volume_get = proc do |fqdn|
          acc = []
          matched_vols = connection.volumes.all('tag-value'=>fqdn)
          ui.warn("Multiple volumes found") if matched_vols.size > 1
          vol = matched_vols.first
          ui.msg("Found volume with id: #{vol.id} "\
                 "#{'in '+@bs.stack if @bs[:stack]}")
          acc << vol
        end

        if @bs[:stack_interpret]
          #
          # Snapshot the entire stack
          #

          stack_def = @bs.get_stack
          stack_def.profiles.each do |p,info|
            profile = @bs.get_profile(p)
            pos = profile.hostname =~ /\%/
            hostname = pos ? profile.hostname[0...pos] + '*' : profile.hostname
            fqdn = [hostname, @bs.subnet,
                    @bs.vpc,  @bs.domain]*'.'
            volumes.concat(volume_get.call(fqdn))

            # Append to server list
            servers.concat(get_servers(@bs.subnet, @bs.vpc, hostname))
          end
        else
          #
          # Snapshot host(s) using filter
          #

          fqdn = [@bs.filter, @bs.subnet,
                  @bs.vpc,    @bs.domain]*'.'
          volumes.concat(volume_get.call(fqdn))
          servers.concat(get_servers(@bs.subnet, @bs.vpc, @bs.filter))
        end

        #
        # Get volumes for servers
        #
        Parallel.map(servers, :in_threads =>
                              config[:batch_size].to_i) do |server|
          begin
            puts "\nSearching volume id for server : #{server.tags['fqdn']}"
            volumes.concat(
              server.volumes.select do |x|
                # Ignore temp and root drives
                x.delete_on_termination == false
              end
            )
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to find "\
                    "volume id for server: #{server.tags['fqdn']}")
          end
        end
        volumes.flatten
        volumes.uniq! {|v| v.id}
        puts "Total number of volume ids : #{volumes.length}"

        #
        # Start SNAPSHOT Process
        #
        epoch_time = Time.now.to_i
        gm_time = Time.now.gmtime.to_s
        Parallel.map(volumes, :in_threads =>
                              config[:batch_size].to_i) do |volume|
          begin
            puts "\nCreating snapshot for : #{volume.tags['Name']}"
            description = ['knife-bs',
                           volume.tags['Name'],
                           gm_time] * '_'
            snapshot_id = volume.snapshot(description).body['snapshotId']
            sleep(10)
            tags = {}
            tags['Name'] = volume.tags['Name']
            tags['created'] = epoch_time
            tags['subnet'] = config[:subnet]
            tags['device'] = volume.tags['device']
            tags['volume-id'] = volume.id
            ## TODO  \/\/\/\/\/ implement
            # tags['cluster_size'] = servers.size
            tags['version'] = get_version()
            if volume.tags.has_key?('raid')
              tags['raid'] = 'yes'
              tags['raid_version'] =
                volume.tags['raid_version'] if
                volume.tags.has_key?('raid_version')
            end
            puts "\nCreating tags for snapshot : #{snapshot_id}"
            connection.create_tags(snapshot_id, tags)
            #snapshots << connection.snapshots.get(snapshot_id)
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying"\
                    " to snapshot: #{volume.tags['Name']}")
          end
        end

        ui.msg("\nThe snapshot process has been started. "\
               "It may take many minutes to several hours."\
               "\nPlease check the AWS console or use the following command..")
        print ui.color("\n\n\tknife bs snapshot VPC.SUBNET "\
                       "(HOSTNAME) [-p | --progress]\n\n",
                       :magenta)

        print_messages
        # print_time_taken
        print "#{ui.color("\nDone!\n\n", :bold)}"
      end

      def show_progress
        print ui.color("\n\nPress Ctrl+C to exit..\n\n", :bold)
        bar = progressbar("#{@bs.subnet} snapshot progress")
        ## GOOD/OK so far
        # Calculate the filter for search
        suffix = ".#{@bs.subnet}.#{@bs.vpc}.#{@bs.domain}"
        if name_args.size == 1
          filter = "*" + suffix
        else
          filter = name_args.last + suffix
        end
        # Show progress until Ctrl+C is pressed or until it is 100% done
        while true
          begin
            snapshots = connection.snapshots.all('tag-value'=> filter)
            values = []
            snapshots.each do |s|
              if s.progress.nil?
                values << 0
              else
                values << s.progress.split('%').first
              end
            end
            overall_progress = get_overall_progress(values)
            progress(overall_progress)
            if overall_progress == 100
              print "#{ui.color("\n\nDone!\n", :bold)}"
              exit 0
            end
            sleep(10)
          rescue SystemExit=>e
            print "#{ui.color("\n\nExiting.\n\n", :bold)}"
            exit 0
          rescue Exception=>e
            ui.warn("Exception: #{e.message}")
            exit 1
          end
        end
      end

      def get_overall_progress(values)
        # Return a root mean square of all the values
        new_values = []
        values.each {|x| new_values << x.to_i }
        return new_values.quadratic_mean.to_i
      end

      def validate!
        ## TODO something
      end

      def get_version()
        return 5.times.map { [*'0'..'9', *'a'..'z', *'A'..'Z'].sample }.join
      end
    end
  end
end
