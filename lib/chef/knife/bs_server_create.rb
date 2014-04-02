# -*- coding: utf-8 -*-
require 'rubygems'
require 'chef/knife/bs_base'
require 'chef/knife/ec2_server_create'
require 'parallel'
require 'fog'
require 'knife-bs/monkey_patches/hash'
require 'pry'

class Chef
  class Knife
    class BsServerCreate < Knife::Ec2ServerCreate

      include Knife::BsBase

      deps do
        require 'fog'
        require 'erubis'
        require 'rubygems'
        require 'fileutils'
        require 'tmpdir'
        require 'readline'
        require 'parallel'
        require 'chef/json_compat'
        require 'chef/knife/bootstrap'
        Chef::Knife::Bootstrap.load_deps
      end

      banner "
############################################################################
----------------------------------------------------------------------------
knife bs server create VPC.SUBNET PROFILE (options)
----------------------------------------------------------------------------

Create instances in EC2. Create single/multiple/ Permanent/Spot instances,
with attached temp/permanent EBS storage, bootstraped with Chef, inside or
outside the VPC, with Cloudwatch applied.
Usage:
To create slaves, with 1TB EBS volumes, with ami matching the master:
    knife bs server create ame1.dev cluster slave --count 9 --perm 1000 --match
To create a slave instance outside VPC:
    knife bs server create ame1.ops cluster slave --novpc

To skip Chef        => --nochef
To skip Spot        => --nospot
To skip CloudWatch  => --nocw

EBS Volumes: If you want to create ebs volumes with your instance, they need
to be explicitly stated in the yaml. E.g.: Placing the following inside any
instance type will mount the specified volumes to the specified directory.

volume:
  ebs:
    /dev/sdf:
      mount: /ebs
      format: ext4

    /dev/sdg:
      mount: /ebsg
      format: ext3

    /dev/sdc:
      mount: /mnt
      format: ext4
      temp: true
      size: 120

For the above config, on the command line while CREATING NEW ebs volume
you need to pass the size by specifying the --ebs flag. E.g. --ebs 200,300

knife bs server create ame1.dev cluster master --ebs 200,300

This will create two new volumes of size 200 and 300. If the number of volumes
specified in the yaml and on the cmd line mismatch then it will error out.

If a server has many EBS volumes in EC2, then only the devices in the yaml which
match will be mounted upon server creation.

RAID: To create raid with two or more volumes, in the yaml provide the raid_device
to be created for all the volumes which are a part of the raid. E.g.

volume:
      /dev/sdf:
        raid_device: ebs
      /dev/sdg:
        raid_device: ebs

knife bs server create ame1.dev cluster master --ebs 200,300

This will create two volumes of size 200,300 and make them part of a raid.
The raid device name will be ebs and will be mounted on /ebs.

To recreate the server with raid volumes, both the devices /dev/sdf and/dev/sdg
need to be specified in the yaml or else those volumes will not be attached.
############################################################################
"
      ## CLUSTER?
      option :flavor,
             :short => "-f FLAVOR",
             :long => "--flavor FLAVOR",
             :description => "The instance type of server (m1.small, m1.medium, etc)",
             :proc => Proc.new { |f| Chef::Config[:knife][:flavor] = f }

      ## OK
      option :identity_file,
             :short => '-i IDENTITY_FILE',
             :long => '--identity-file IDENTITY_FILE',
             :description => 'The SSH identity file used for authentication'

      option :bootstrap_version,
             :long => '--bootstrap-version VERSION',
             :description => 'The version of Chef to install',
             :proc => Proc.new { |v| Chef::Config[:knife][:bootstrap_version] = v }

      option :distro,
             :short => '-d DISTRO',
             :long => '--distro DISTRO',
             :description => 'Bootstrap a distro using a template',
             :proc => Proc.new { |d| Chef::Config[:knife][:distro] = d }

      ## CLUSTER?
      option :run_list,
             :short => '-r RUN_LIST',
             :long => '--run-list RUN_LIST',
             :description => 'Comma separated list of roles/recipes to apply',
             :proc => lambda { |o| o.split(/[\s,]+/) }

      option :wait,
             :short => '-W SECONDS',
             :long => '--wait SECONDS',
             :description => 'Number of seconds between batches.',
             :default => 0.5

      ## CLUSTER?
      option :number_of_nodes,
             :short => '-n NODES',
             :long => '--count NODES',
             :description => 'Number of nodes to provision. Default: 1',
             :default => 1

      option :batch_size,
             :short => '-B SIZE',
             :long => '--batch-size SIZE',
             :description => 'Number of parallel processes to run per batch.'

      option :stop_on_failure,
             :short => '-F',
             :long => '--stop-on-failure',
             :description => 'Stop on first failure of remote command',
             :default => false

      ## CLUSTER? what about suffix?
      option :amiprefix,
             :short => '-a AMIPREFIX',
             :long => '--amiprefix AMIPREFIX',
             :description => 'The ami prefix to use, if ami-suffix is provided in the yaml.'

      ## OK
      option :dry_run,
             :long => '--mock',
             :description => "Don't really run, just use mock calls"

      ## CLUSTER?
      option :ebs,
             :long => '--ebs SIZE1,[SIZE2..]',
             :description => 'The size of new Permanent EBS volume to'\
                             ' create in GB, for EBS-backed instances',
             :proc => lambda { |o| o.split(/[\s,]+/) }

      ## CLUSTER?
      option :ebs_optimized,
             :long => '--ebs-optimized',
             :description => 'Enabled optimized EBS I/O'

      ## CLUSTER?
      option :price,
             :short => '-p PRICE',
             :long => '--spot-price PRICE',
             :description => 'The max spot price to be set'

      ## CLUSTER?
      option :hostname,
             :short => '-N NAME',
             :long => '--node-name NAME',
             :description => 'The hostname of the node to be set'

      option :latest,
             :long => '--latest',
             :description => 'Automatically select the latest ami'

      option :match,
             :long => '--match',
             :description => 'Match the master AMI'

      ## REVIEW - same as --mock?
      option :only_config,
             :long => '--dryrun',
             :description => 'Print config and exit'

      option :quit_at,
             :short => '-q STAGE',
             :long => '--quit STAGE',
             :description => 'Quit after x number of stages',
             :default => 100

      ## CLUSTER?
      option :skip_chef,
             :long => '--nochef',
             :description => 'Skip Chef Bootstrap'

      ## REVIEW
      option :novpc,
             :long => '--novpc',
             :description => 'Create instance(s) outside the VPC'

      option :nospot,
             :long => '--nospot',
             :description => "Don\'t create a spot instance"

      option :nocloudwatch,
             :long => '--nocw',
             :description => "Skip cloudwatch for this instance"

      option :raid,
             :long => '--raid',
             :description => "Create a software raid for the attached PERMANENT EBS volumes."

      option :raid_level,
             :long => '--raid-level RAID_LEVEL',
             :description => "Raid level for the devices. Defaults to 0",
             :default => 0

      option :attach_volume,
             :long => '--attach',
             :description => 'To attach and EBS volume by searching the FQDN tag'

      option :associate_elastic_ip,
             :long => '--eip',
             :description => "Associate an Elastic IP with the Instance."

      option :restore_from_snapshot,
             :long => '--restore',
             :description => "Restore the cluster from snapshot. By default it restores from the same subnet."

      option :from,
             :short => '-f SUBNET',
             :long => '--from SUBNET',
             :description => 'Restore snapshots from given subnet.'

      option :stack,
             :long => '--stack',
             :description => 'Interpret second arg as stack, not profile'
             # This maintains our default of spinning up profiles

      def run
        ## TODO review verbosity levels
        $stdout.sync = true
        config[:verbosity] = 2 if config[:only_config]

        if config[:dry_run]
          ui.msg(ui.color('Initiating dry run', :bold))
          Fog.mock!
          Fog::Mock.delay = 0
        end

        build_config(name_args)
        print_config
        exit 1 if @bs[:only_config]
        # Used to store instance data
        @bs[:associations] = {}
        check_for_existing_chef_objects
        ui.msg(ui.color("Provisioning #{@bs.number_of_nodes} servers.",
                        :magenta))
        create_servers
        print_dns_info
        wait_until_ready
        tag_servers
        associate_eips if @bs[:associate_elastic_ip]
        restore_from_snapshots if @bs[:restore_from_snapshot]
        attach_ebs_volumes if @bs[:attach_volume]
        create_ebs_volumes if @bs[:create_ebs]
        setup_volumes
        validate!
        check_ssh
        pre_bootstrap
        ## REVIEW why can't novpc instances be bootstrapped?
        bootstrap_servers unless @bs[:skip_chef] or @bs[:novpc]
        post_bootstrap
        reboot_servers

        # Done!
        print_messages
        print_cluster_info(@bs.servers, @bs.nodes, 'full')
        print_time_taken
        ui.msg(ui.color("\nDone!\n\n", :bold))
      end

      def build_config(name_args)
        if name_args.size < 2
          show_usage
          exit 1
        end
        name_args.reverse!
        config[:vpc], config[:subnet] = name_args.pop.split('.')
        case name_args.size
        when 1
          unless config[:stack]
            config[:profile] = name_args.pop
          else
            # Only stack is provided, spin up all profiles
            config[:stack] = name_args.pop
          end
        when 2
          config[:stack], config[:profile] = name_args
        end
        base_config(mixins = ['cloudconf', 'ddns']) # --> @bs

        Chef::Config[:knife][:image] = get_ami_id

        ## MOVE this to mixin.rb?
        @bs.mixins.tag.configure do |tagmixin|
          subst = proc do |value|
            t = tagmixin.data
            binding.eval('"' + value + '"')
          end
          tagmixin.data.each do |tag,val|
            tagmixin.data[tag] = subst.call(val)
          end
        end

        @bs.mixins.volume.configure do |volmixin|
          # First add all of the available ephemeral devices
          flv = connection.flavors.get(@bs.flavor)
          num_eph = flv.instance_store_volumes
          if num_eph > 1
            volmixin.data[:ephemeral_available] =
              ('b'..'z').take(num_eph).each_with_object([]) do |letter, arr|
              arr << "/dev/xvd#{letter}"
            end
          end

          # RP-2505 if no ephemeral drives are configured and there are
          # no temp devices being created, fail
          ## REVIEW this behavior
          temp_devices = volmixin.get_temp_devices
          if temp_devices.size == 0
            raise Exception.new 'No instance storage (temp or ephemeral)'
          end

          # Check for conflicting mount definitions
          mounts = volmixin.get_mounts
          non_unique = mounts.uniq.
            map { | e | [mounts.count(e), e] }.
            select { | c, _ | c > 1 }.
            sort.reverse.
            map { | c, e | "#{e}: #{c} times" }

          if non_unique.size > 0
            raise Exception.new "duplicated mount, check yaml:\n#{non_unique}"
          end
          ## TODO check for conflicting raid names
          ## TODO if definition exists but no mount, error
          ## TODO check ephemerals to exist in available
        end

        ## REVIEW need to be able to do this per server?
        Chef::Config[:knife][:aws_user_data] = build_cloud_config

        profconf = @bs.get_profile

        # if price is specified in the yaml or via cmd line parameters, 
        # then we create a spot instance
        ## TODO adapt for cluster create...
        @bs.mixins.price.configure do |pricemix|
          pricemix.data = @bs[:price] if @bs[:price]
          @bs[:create_spot] = true if pricemix.data
        end

        @bs[:subnet_id] = get_subnet_id([@bs.vpc, @bs.subnet] * '.')
        # check for ip address in the yaml
        if profconf.has_key? :ipaddress
          @bs[:private_ip_address] =
            @bs.subnet_cidr_block.gsub('0/24', profconf.ipaddress.to_s)
        end

        # check for cloudwatch
        unless not profconf.has_key? :cloudwatch || @bs.create_spot
          @bs[:cw_set_alarms] = true
        end

        unless @bs[:skip_chef]
          if @bs.mixins[:chef] && @bs.mixins.chef.data[:run_list]
            @bs[:run_list] ||= @bs.mixins.chef.data.run_list
            config[:run_list] = @bs[:run_list]
          end
        end

        unless (@bs[:skip_chef] || @bs[:run_list])
          ui.err("Empty chef runlist. If intentional, run with --nochef")
          show_usage
          exit 1
        end

        # Check for count in the yaml
        ## FUTURE fix using stack definition
        ## Maybe create a new bs_stack_create.rb ?
        unless @bs[:number_of_nodes]
          ## FUTURE count will be part of a stack definition
          if profconf[:count]
            @bs[:number_of_nodes] = profconf[:count]
          else
            puts 'No count specified in the parameters or in the yaml. Exiting.'
            exit 1
          end
        end

        # Integrate command line args into volume mixin
        if @bs.mixins[:volume] && @bs.mixins.volume.data[:ebs]
          # If --ebs is provided, then create volumes, do not attach
          # If --ebs is not provided, then attach volumes whether
          #    or not --attach is given
          @bs[:create_ebs]    = !! @bs[:ebs]
          @bs[:attach_volume] = (! @bs[:create_ebs]) | @bs[:attach_volume]
          if @bs[:ebs]
            @bs.ebs.reverse!
            @bs.mixins.volume.configure do |vmix|
              vmix.data[:ebs].each do |v, info|
                next if info[:size]
                info[:size] = @bs[:ebs].pop
                raise ArgumentError.new("Not enough size args") unless info[:size]
              end
              ui.warn("Too many size parameters "\
                      "(left: #{@bs[:ebs].inspect})") unless @bs[:ebs].empty?
            end
          else
            @bs[:ebs] = nil
          end
        else
          ui.error("No volume data is defined for this instance type")
        end

        @bs[:batch_size] ||= @bs[:number_of_nodes]
        @bs[:nodes]        = []

        generate_node_names
        ui.msg(@bs.nodes)
      end

      def build_cloud_config
        @bs.mixins.cloudconf.configure do |ccmixin|
          ccmixin.data[:apt_config] = @bs.mixins.apt.cloud_config
          #hook_config = @bs.mixins.hooks.cloud_config
          # To make the cloud config that you want, edit here. Would be
          # nice if this was templated
        end
        @bs.mixins.cloudconf.build
      end

      ## FUTURE all of the FQDN manipulation needs to be rethought
      def check_for_existing_chef_objects
        Parallel.map(@bs.nodes, in_threads: @bs.batch_size.to_i) do |node|
          fqdn = node.split('.')
          node_name = fqdn[0] + '.' + fqdn[1]
          cleanup_chef_objects(node_name) if chef_objects_dirty?(node_name)
        end
      end

      def create_servers
        if @bs[:create_spot] and not @bs[:nospot]
          create_spot_instances([@bs.vpc, @bs.subnet] * ':')
        else
          create_instances
        end
        ui.msg(ui.color("Instance ID's:",:magenta))
        ui.msg(ui.color("#{@bs.instance_ids.join(', ')}", :bold))
      end

      # Moved from BsBase to cleanup, only used here. create_spot_instances used
      # by bs_ami so left in BsBase
      def create_instances
        min_count = max_count = @bs.number_of_nodes
        puts "\nCreating #{max_count} on-demand instance(s)"
        options = {
          'ClientToken'     => generate_token,
          'KeyName'         => Chef::Config[:knife][:aws_ssh_key_id],
          'InstanceType'    => @bs.flavor,
          'SubnetId'        => @bs[:novpc] ? nil : @bs.subnet_id,
          'Placement.AvailabilityZone' => @bs.mixins.az.data,
          'SecurityGroupId' => @bs.mixins.sg.data
        }
        options['EbsOptimized'] = !! @bs[:ebs_optimized]

        ## REVIEW
        if ami.root_device_type == "ebs"
          ami_map = ami.block_device_mapping.first
          block_device_mapping = {
            'DeviceName'              => ami_map['deviceName'],
            'Ebs.VolumeSize'          => ami_map['volumeSize'].to_s,
            'Ebs.DeleteOnTermination' => ami_map['deleteOnTermination']
          }
          options['BlockDeviceMapping'] = [block_device_mapping]
        end

        ## Optionally only include mapped devices
        ## This way we get all of the ephemeral drives, some unmapped however
        if @bs.mixins.volume.data[:ephemeral_available]
          ephmap = @bs.mixins.volume.data.ephemeral_available.each_with_index.map do |d,i|
            {
              'VirtualName' => "ephemeral#{i}",
              'DeviceName'  => d
            }
          end
          options['BlockDeviceMapping'].concat( ephmap )
        end

        if (max_count == 1) and @bs[:private_ip_address]
          options['PrivateIpAddress'] = @bs.private_ip_address
          puts "Assigning IP ADDRESS : #{options['PrivateIpAddress']}"
        end

        if Chef::Config[:knife][:aws_user_data]
          begin
            options['UserData'] = File.read(Chef::Config[:knife][:aws_user_data])
          rescue
            ui.warn("Cannot read #{Chef::Config[:knife][:aws_user_data]}: #{$!.inspect}. Ignoring option.")
          end
        end

        # -----------------------------------------------------------------
        tries = 5
        print_table(options, 'Launch Config')
        begin
          puts "\nSending request..."
          response = connection.run_instances(@bs.image, min_count,
                                              max_count, options)
          ui.msg(response.inspect)
        rescue Exception => e
          ui.warn("#{e.message}\nException creating instances")
          if (tries -= 1) <= 0
            ui.warn("\n\nMax tries reached. Exiting.\n\n")
            exit 1
          else
            ui.msg("Trying again.\n")
            retry
          end
        end
        # now we have our servers
        instances = response.body['instancesSet']
        # select only instances that have instanceId key and collect those ids
        # into an array
        @bs[:instance_ids] = instances.select {|i| i.has_key?('instanceId')}.collect do |i|
          i['instanceId']
        end

        puts "\nNumber of instances started: #{@bs.instance_ids.size}\n"
        sleep 10
        puts "Getting servers.."
        # collect an array of servers retrieved based on the instance ids we
        # obtained above
        @bs[:servers] = @bs.instance_ids.collect do |id|
          begin
            server = connection.servers.get(id)
          rescue Exception => e
            sleep 7
            retry
          end
          raise Ec2Error.new("server #{id} was nil") if server.nil?
          server
        end
      end

      def print_dns_info
        if vpc_mode?
          server_dns_map = @bs.servers.map do |x|
            {
              'ID' => x.id,
              'Subnet ID' => x.subnet_id,
              'Private IP Address' => x.private_ip_address
            }
          end
        else
          server_dns_map = @bs.servers.map do |x|
            {
              'ID' => x.id,
              'Public DNS Name' => x.dns_name,
              'Public IP Address' => x.public_ip_address,
              'Private DNS Name' => x.private_dns_name,
              'Private IP Address' => x.private_ip_address
            }
          end
        end
        server_dns_map.each do |server|
          print_table(server)
        end
      end

      def wait_until_ready
        Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
          begin
            ui.msg(ui.color("Waiting for server state to be ready on : #{server.id}", :magenta))
            server.wait_for { print '.'; ready? }
            @bs.associations[server.id] = {}
          rescue SystemExit, Exception => e
            @bs.servers.delete(server)
            server.destroy
            ui.warn("#{e.message}\nCaught SystemExit, Exception while waiting for #{server.id} to be ready. Destroying.")
            exit 1 if @bs.servers.length == 0
          end
        end
      end

      def associate_eips
        Parallel.map(@bs.servers, :in_threads => @bs.batch_size.to_i) do |server|
          begin
            associate_elastic_ip(server)
          rescue Exception => e
            ui.warn("#{e.message}\nException while associating Elastic IP for #{server.id}")
          end
        end
      end

      def tag_servers
        Parallel.map(@bs.servers.count.times.to_a, in_threads: @bs.batch_size.to_i) do |num|
          begin
            server = @bs.servers[num]
            ui.color("Creating tags on #{@bs.associations[server.id]['fqdn']}(#{server.private_ip_address})\n", :magenta)
            fqdnsplit = @bs.nodes[num].split('.')
            chef_node_name = fqdnsplit[0].to_s + '.' + fqdnsplit[1].to_s
            @bs.associations[server.id]['chef_node_name'] = chef_node_name
            @bs.associations[server.id]['fqdn'] = @bs.nodes[num]
            create_server_tags(server, fqdnsplit[0].to_s)
          rescue SystemExit, Exception=>e
            server.destroy
            @bs.servers.delete(server)
            ui.warn("#{e.message}\nCaught SystemExit, Exception while creating tags for #{@bs.nodes[num]}. Destroying server and proceeding..")
            exit 1 if @bs.servers.size == 0
          end
        end
      end

      def restore_from_snapshots
        @bs[:attach_volume] = true
        @bs[:create_ebs] = false
        @bs[:from] ||= @bs[:subnet]
        Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
          begin
            assoc = @bs.associations[server.id]
            puts "\nGetting Snapshot and Volume for #{assoc['fqdn']}"
            assoc['snapshot'] =
              connection.snapshots.all('tag-value' =>
                                       assoc['fqdn'].gsub(@bs.subnet,
                                                          @bs.from)).
              sort_by {|x| x.tags['created'] }.last

            puts "\nCreating new volume from snapshot for #{assoc['fqdn']}"
            assoc['new_volume'] = create_volume_from_snapshot(assoc['snapshot'])

            puts "\nWaiting for new volume #{assoc['new_volume'].id} to be ready for #{assoc['fqdn']}.."
            ## REVIEW assoc usage is not good here
            ##
            assoc['new_volume'].wait_for {print '.'; ready?}

            puts "\nCreating tags for new volume : #{assoc['fqdn']}"
            tags = {
              'Name'              => assoc['fqdn'],
              'bs-owner'          => assoc['fqdn'],
              'vol_from_snapshot' => @bs.from,
              'subnet'            => @bs.subnet,
              'device'            => '/dev/sdf'
            }
            create_tags(assoc['new_volume'].id, tags)
          rescue SystemExit, Exception => e
            ui.warn("#{e.message}\nCaught exception while trying to restore"\
                    " volume from snapshot for server: "\
                    "#{@bs.associations[server.id]['fqdn']}")
          end
        end
      end

      def setup_volumes
        Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
          ## REVIEW possible threading issues, find a common sol'n
          @bs.mixins.volume.configure do |v|
            v.volume_functions(server)
            v.bs_ebs_functions(server)       if v.data[:ebs]
            v.bs_ephemeral_functions(server) if v.data[:ephemeral]
            v.bs_swap_functions(server)      if v.data[:swap]
            v.bs_bind_functions(server)      if v.data[:bind]

            # Install/launch init script
            v.bs_volume_init(server)
          end
        end
      end

      def attach_ebs_volumes
        Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
          begin
            ## TODO get rid of associations or expand it for generic
            ## per-server data storage
            fqdn = @bs.associations[server.id]['fqdn']
            ui.msg(ui.color("Attaching volume(s) to : #{fqdn} "\
                            "(#{server.private_ip_address})", :magenta))

            # Retrieves all EBS volumes tagged with this fqdn
            volumes = get_volumes(fqdn)
            raise RuntimeError.new("No volumes found for tag #{fqdn} "\
                                   "(#{server.private_ip_address})") if volumes.size == 0
            puts "\nNumber of EBS volumes: #{volumes.size}"

            @bs.mixins.volume.configure do |vmix|
              volumes.each do |v|
                # Retrieve data from YAML pertaining to this drive
                info = vmix.data.ebs[v.tags['device']]
                raise RuntimeError.new("Volume #{v.tags['device']}"\
                                       " not defined") unless info
                puts "Mount point : #{@bs.mixins.volume.get_mount(v.tags['device'])}"
                # Attach the volume to the instance
                attach_volume(server, v.id, v.tags['device'])
                ## TODO ##

                ## WARN if the attached drive is not in CONFIG or FSTAB

                ## ERROR out if after ATTACHING existing drives and
                ## CREATING new ones there is not enough to fulfill the
                ## RAID array
              end
            end
          rescue SystemExit, Exception => e
            ui.warn("#{e.message}\nCaught SystemExit, Exception while attaching"\
                    " EBS volume for #{@bs.associations[server.id]['fqdn']}.")
          end
        end
      end

      def create_ebs_volumes
        Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
          begin
            assoc = @bs.associations[server.id]
            ui.msg(ui.color("Creating new EBS volume(s) for node "\
                            "#{assoc['fqdn']} (#{server.private_ip_address})",
                            :magenta))

            @bs.mixins.volume.data.ebs.each do |d, info|
              create_volume(server, d.gsub('_', '/'),
                            info, assoc['fqdn'])
            end

          rescue SystemExit, Exception => e
            ui.warn("#{e.message}\nCaught SystemExit, Exception while"\
                    " creating new EBS volume for #{assoc['fqdn']}.")
          end
        end
      end

      def check_ssh
        Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
          begin
            assoc = @bs.associations[server.id]
            ui.msg(ui.color("Waiting for sshd on #{assoc['fqdn']} (#{server.private_ip_address})",
                            :magenta))
            fqdn = vpc_mode? ? server.private_ip_address : server.dns_name
            print('.') until tcp_test_ssh(fqdn, @bs.ssh_port) {
              sleep (vpc_mode? ? 30 : 10)
              ui.msg("\n#{@bs.associations[server.id]['fqdn']} ready")
            }
          rescue SystemExit, Exception => e
            ui.warn("#{e.message}\nSystemExit, Exception while waiting "\
                    "for SSHD #{@bs.associations[server.id]['fqdn']}.")
          end
        end
      end

      def pre_bootstrap
        Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
          begin
            @bs.mixins.var.configure do |vmix|
              vmix.sdata[server.id] = {}
              vmix.sdata[server.id]['HOSTNAME'] =
                @bs.associations[server.id]['chef_node_name']
              vmix.sdata[server.id]['FQDN'] =
                @bs.associations[server.id]['fqdn']
            end

            # Installs /etc/bs.vars and updates ~ubuntu/.bashrc
            @bs.mixins.var.add_vars(server) if @bs.mixins[:var]

            # Instead of having add_general_commands, take care of the
            # rest of the mixins here, including ones that we don't have
            # prescience of
            @bs.mixins.hooks.apply(server, 'before_chef') if @bs.mixins[:hooks]
            @bs.mixins.ssh_keys.authorize(server) if @bs.mixins[:ssh_keys]

            ## Figure out a better way to store DNS info
            if @bs[:skip_chef]; @bs.mixins.ddns.configure do |d|
                [:subnet,
                 :vpc,
                 :domain].each { |e| d.data[e] = @bs[e] }
                d.data[:assoc] = @bs.associations
              end
              @bs.mixins.ddns.setup(server)
            end

            ssh = Chef::Knife::Ssh.new
            ssh.ui = ui
            ssh.config[:ssh_user] = Chef::Config[:knife][:ssh_user] || @bs.ssh_user || 'ubuntu'
            ssh.config[:ssh_password] = @bs[:ssh_password]
            ssh.config[:ssh_port] = Chef::Config[:knife][:ssh_port] || @bs.ssh_port|| 22
            ssh.config[:identity_file] = @bs[:identity_file] || Chef::Config[:knife][:identity_file]
            ssh.config[:manual] = true
            ssh.config[:host_key_verify] = false
            ssh.config[:on_error] = :raise

            # Run all built up mixin commands
            ui.msg(ui.color("[BEFORE_CHEF] Starting mixin "\
                            "deployment/configuration", :green))
            BsMixin.exec('before_chef', ssh, @bs.associations[server.id]['fqdn'], server)
          rescue SystemExit, Exception => e
            ui.warn("#{e.message}\nSystemExit, Exception while running "\
                    "commands for #{@bs.associations[server.id]['fqdn']}.")
          end
        end
      end

      def bootstrap_servers
        Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
          begin
            ui.msg(ui.color("\nBootstrapping Chef on "\
                            "#{@bs.associations[server.id]['fqdn']}\n",
                            :magenta))
            fqdn = vpc_mode? ? server.private_ip_address : server.dns_name
            bootstrap = bootstrap_for_linux_node(server, fqdn)
            bootstrap.config[:chef_node_name]    =
              @bs.associations[server.id]['chef_node_name'] || server.id
            bootstrap.config[:bootstrap_version] = @bs.bootstrap_version
            bootstrap.config[:distro]            = @bs.distro
            bootstrap.run
            node, client = get_chef_node_client(@bs.associations[server.id]['chef_node_name'])
            node.chef_environment = @bs.mixins.chef.data.env
            node.save
          rescue SystemExit, Exception => e
            ui.warn("#{e.message}\nException while bootstrapping "\
                    "#{@bs.associations[server.id]['fqdn']}.")
          end
        end
      end

      def post_bootstrap
        Parallel.map(@bs.servers, in_threads: config[:batch_size].to_i) do |server|
          begin
            @bs.mixins.hooks.apply(server, 'after_chef') if @bs.mixins[:hooks]
            ## TODO have one ssh object that you pass around
            ssh = Chef::Knife::Ssh.new
            ssh.ui = ui
            ssh.config[:ssh_user] = Chef::Config[:knife][:ssh_user] || @bs.ssh_user || 'ubuntu'
            ssh.config[:ssh_password] = @bs[:ssh_password]
            ssh.config[:ssh_port] = Chef::Config[:knife][:ssh_port] || @bs.ssh_port|| 22
            ssh.config[:identity_file] = Chef::Config[:knife][:identity_file] || @bs[:identity_file]
            ssh.config[:manual] = true
            ssh.config[:host_key_verify] = false
            ssh.config[:on_error] = :raise
            BsMixin.exec('after_chef', ssh, @bs.associations[server.id]['fqdn'], server)
          rescue SystemExit, Exception => e
            ui.warn("#{e.message}\nException doing post-bootstrap "\
                    "#{@bs.associations[server.id]['fqdn']}.")
          end
        end
      end

      def reboot_servers
        ui.msg(ui.color("\nRebooting Instance(s) \n", :magenta))
        response = connection.reboot_instances(@bs.instance_ids)
        if response.body['return']
          Parallel.map(@bs.servers, in_threads: @bs.batch_size.to_i) do |server|
            begin
              ui.msg(ui.color("Waiting for server state to be RUNNING on: "\
                              "#{@bs.associations[server.id]['fqdn']}",
                              :magenta))
              server.wait_for { print '.'; server.ready? }
            rescue SystemExit, Exception => e
              ui.warn("#{e.message}\nSystemExit, Exception "\
                      "waiting for instance to be running on "\
                      "#{@bs.associations[server.id]['fqdn']}. Proceeding")
            end
          end
        else
          ui.error('Error rebooting instances.')
        end
      end

      def validate!
        super
        errs = []
        ip = @bs[:private_ip_address]
        @bs.mixins.each do |name,m|
          case name
          when 'volume'
            errs.concat(m.validate_ebs(@bs))
          else
            errs.concat(m.validate)
          end
        end
        ## Commented out because the order of invocation changed.
        # if ip_used?(ip)
        #   errs << "The IP address #{@bs.private_ip_address} is already in use!" 
        # end
        errs.each {|e| ui.fatal(e)} and exit 1 unless errs.empty?
      end
    end
  end
end
