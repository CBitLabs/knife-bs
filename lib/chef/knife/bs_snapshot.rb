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
knife bs snapshot VPC.SUBNET (HOSTNAME) (options)
----------------------------------------------------------------------------

Snapshot the attached EBS volumes of a list of servers.
You can snapshot an entire cluster(master+slaves) or just a specific server.
Usage:
To snapshot the entire dev cluster:
    knife bs snapshot ame1.dev
To snapshot just a single server, say ms101.dev
    knife bs snapshot ame1.dev  ms101
To snapshot servers based on a given name regex
    knife bs snapshot ame1.dev  cm*
    knife bs snapshot ame1.dev  rs*
############################################################################
"
      option :only_config,
             :long => '--dryrun',
             :description => 'Print config and exit'

      option :progress,
             :short => '-p',
             :long => '--progress',
             :description => 'Print progress of the snapshot'


      def run
        ## TODO rewrite this:
        ## Use volume mixin, stack information, improve 'regex'
        #
        # Put Fog into mock mode if --dry_run
        #
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end
        $stdout.sync = true

        unless name_args.size > 0
          show_usage
          exit 1
        end

        config[:verbosity] = 2 if config[:only_config]
        config[:verbosity] = -1 if config[:progress]
        build_config(name_args)
        exit 1 if config[:only_config]

        if config[:progress]
          show_progress(name_args)
        end

        volumes = []
        servers = []
        snapshots = []

        if name_args.size == 1
          #
          # Snapshot the entire cluster
          #
          # Find master volume
          fqdn = "ms101" + "." + "#{config[:subnet]}" + "." + "#{config[:vpc]}" + "." + "#{config[:domain]}"
          master_volume = connection.volumes.all('tag-value'=>fqdn).first
          puts "\nFound master volume with id: #{master_volume.id}"
          volumes << master_volume

          # Find slave servers
          puts "Searching slaves..."
          name_args << "rs*"

          servers = get_servers(name_args)
          puts "Found slaves : #{servers.length}"
        else
          #
          # Snapshot just the given server(s)
          #
          servers = get_servers(name_args)
        end

        #
        # Get volumes for servers
        #
        Parallel.map(servers, :in_threads => config[:batch_size].to_i) do |server|
          begin
            puts "\nSearching volume id for server : #{server.tags['fqdn']}"
            vols = server.volumes.select {|x| x.delete_on_termination == false }
            vols.each {|v| volumes << v}
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to find volume id for server: #{server.tags['fqdn']}")
          end
        end
        volumes.flatten
        puts "Total number of volume ids : #{volumes.length}"

        #
        # Start SNAPSHOT Process
        #
        epoch_time = Time.now.to_i
        gm_time = Time.now.gmtime.to_s
        Parallel.map(volumes, :in_threads => config[:batch_size].to_i) do |volume|
          begin
            puts "\nCreating snapshot for : #{volume.tags['Name']}"
            description = 'knife-bs' + '_' + volume.tags['Name'] + '_' + gm_time
            snapshot_id = volume.snapshot(description).body['snapshotId']
            sleep(10)
            tags = {}
            tags['Name'] = volume.tags['Name']
            tags['created'] = epoch_time
            tags['subnet'] = config[:subnet]
            tags['cluster_size'] = servers.size
            tags['version'] = get_version()
            if volume.tags.has_key?('raid')
              tags['raid'] = 'yes'
              tags['raid_version'] = volume.tags['raid_version'] if volume.tags.has_key?('raid_version')
            end
            puts "\nCreating tags for snapshot : #{snapshot_id}"
            connection.create_tags(snapshot_id, tags)
            #snapshots << connection.snapshots.get(snapshot_id)
          rescue SystemExit, Exception=>e
            ui.warn("\n#{e.message}\nCaught exception while trying to snapshot: #{volume.tags['Name']}")
          end
        end

        puts "\nThe snapshot process has been started. It may take many minutes to several hours."
        puts "\nPlease check the AWS console or use the following command.."
        print "#{ui.color("\n\n\tknife bs snapshot progress VPC.SUBNET (HOSTNAME) [-p | --progress]\n\n", :magenta)}"

        print_messages
        print_time_taken
        print "#{ui.color("\nDone!\n\n", :bold)}"
      end

      def show_progress(name_args)
        print "#{ui.color("\n\nPress Ctrl+C to exit..\n\n", :bold)}"
        bar = progressbar("#{config[:subnet]} snapshot progress")
        # Calculate the filter for search
        suffix = ".#{config[:subnet]}.#{config[:vpc]}.#{config[:domain]}"
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

      def get_version()
        return 5.times.map { [*'0'..'9', *'a'..'z', *'A'..'Z'].sample }.join
      end
    end
  end
end
