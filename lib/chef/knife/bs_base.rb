require 'chef/knife'
require 'chef/knife/ec2_base'
require 'chef/knife/ec2_server_create'
require 'chef/knife/bootstrap'
require 'terminal-table'
require 'stringio'
require 'yaml'
require 'time'
require 'kwalify'
require 'ruby-progressbar'
require 'chef/bs_utils/bs_logging'
require 'knife-bs/monkey_patches/ui'
require 'awesome_print'
require 'knife-bs/errors'
require 'pry'

class Chef
  class Knife
    module BsBase
      ## TODO redo verbosity level (monkey patch UI)
      include ::BsUtils::BsLogging
      def self.included(includer)
        includer.class_eval do
          deps do
            require 'fog'
            require 'erubis'
            require 'net/scp'
            require 'fileutils'
            require 'readline'
            require 'chef/json_compat'
            require 'chef/knife/bs_mixin'
          end

        option :yaml,
          :short => '-Y YAML',
          :long => '--yaml YAML',
          :description => 'Path to bs-atlas.yaml config file'

        option :aws_access_key_id,
          :short => '-A KEY',
          :long => '--aws-access-key-id KEY',
          :description => 'Your AWS Access Key ID',
          :proc => Proc.new { |key| Chef::Config[:knife][:aws_access_key_id] = key }

        option :aws_secret_access_key,
          :short => '-K SECRET',
          :long => '--aws-secret-access-key SECRET',
          :description => 'Your AWS API Secret Access Key',
          :proc => Proc.new { |key| Chef::Config[:knife][:aws_secret_access_key] = key }

        option :region,
          :long => '--region REGION',
          :description => 'Your AWS region',
          :proc => Proc.new { |key| Chef::Config[:knife][:region] = key }

        option :availability_zone,
          :short => "-Z ZONE",
          :long => "--availability-zone ZONE",
          :description => "The Availability Zone",
          :proc => Proc.new { |key| Chef::Config[:knife][:availability_zone] = key }

        option :bslogging,
          :short => '-b',
          :long => '--no_bslog',
          :boolean => true,
          :description => 'Disables logging knife run to disk',
          :proc => Proc.new { BsUtils::BsLogging.disable }

        option :user_mixins,
          :long => '--mixins MIXIN1,[MIXIN2..]',
          :description => 'Mixins to be applied',
          :proc => lambda { |o| o.split(/[\s,]+/) }
        end
      end

      def connection
        @bs[:connection] ||= begin
          connection = Fog::Compute.new(
            :provider => 'AWS',
            :aws_access_key_id => Chef::Config[:knife][:aws_access_key_id],
            :aws_secret_access_key => Chef::Config[:knife][:aws_secret_access_key],
            :region => locate_config_value(:region)
          )
        end
      end

      def cloudwatch
        @bs[:cloudwatch] ||= begin
          cloudwatch = Fog::AWS::CloudWatch.new(
            :aws_access_key_id => Chef::Config[:knife][:aws_access_key_id],
            :aws_secret_access_key => Chef::Config[:knife][:aws_secret_access_key],
            :region => locate_config_value(:region)
          )
        end
      end

      def associate_elastic_ip(server, elastic_ip=nil)
        # Associate an EIP with a given server. 
        # If #{elastic_ip} is not provided, get a new EIP
        elastic_ip ||= get_elastic_ip
        ui.color("Associating Elastic IP #{eip.public_ip} with Server: #{server.id}...\n\n", :magenta)
        elastic_ip.server=(server)
      end

      ## REVIEW - move to mixin?
      def attach_volume(server, volume_id, device)
        #Volume id and fqdn are provided while creating clusters
        ui.msg("\nTrying to attach Volume : #{volume_id}"\
               " on device #{device}"\
               " to Server : #{server.id}")

        response = connection.attach_volume(server.id, volume_id, device)
        volume = connection.volumes.get("#{response.body['volumeId']}")
        volume.wait_for { print '.' ; state == 'attached' || state == 'in-use'}
        ui.msg("\nVolume attached.")
        print_volume_info(volume.id)
        volume
      end

      ## REVIEW - move to mixin?
      def attach_volumes(server,volumes)
        volumes.each { |v| attach_volume(server, v.id, v.tags['device']) }
      end

      def print_config
        ## TODO print better config
        print_table(Chef::Config[:knife], 'KNIFE CONFIGURATION')
        print_table(@bs.mixins.var.data, 'ENVIRONMENT VARS')
      end

      def base_config(mixins=nil, &block)
        ## ensure that VPC and SUBNET are set at this point
        @bs = BsConfig.new(config, &block)
        @bs.load_yaml
        @bs.load_mixins(mixins)
        # Can load up any additional ones with
        # @bs.load_mixin(name)
        org = @bs.yaml.organizations.first
        @bs[:organization] = org[0]
        @bs[:domain] = org[1].domain

        region, _ = @bs.get_region_vpc

        subnet = @bs.get_subnet
        #stackconf    = @bs.get_stack
        profconf     = @bs.get_profile
        #_, vpcconf = @bs.get_region_vpc

        @bs.mixins.az.configure do |az|
          az.data = (@bs[:availability_zone] || az.data)
        end
        @bs[:region]            ||= region
        if @bs[:vpc] && @bs[:subnet]
          @bs[:subnet_id]         ||= get_subnet_id([@bs.vpc, @bs.subnet]*'.')
        end
        @bs[:distro]            ||= 'chef-full'
        @bs[:hostname]          ||= profconf && profconf.hostname
        @bs[:flavor]            = (profconf && profconf.type) && profconf.type
        @bs[:environment]    = @bs.mixins.chef.data[:env] if @bs.mixins[:chef]
        Chef::Config[:knife][:ssh_user] = @bs[:ssh_user] if @bs[:ssh_user]

        # Adding global env variables that describe the infrastructure
        # within the server (partially for now)
        if @bs[:vpc] && @bs[:subnet]
          @bs.mixins.var.configure do |v|
            v.data['VPCNAME'] =
              [@bs.vpc,
               @bs.domain] * '.'
            v.data['DOMAINNAME'] =
              [@bs.subnet,
               v.data['VPCNAME']] * '.'
          end
        end

        ## FUTURE might be better to use fqdn by default as node name
        ## If you markup domains as a mixin
        if @bs[:vpc] && @bs[:subnet]
          @bs[:chef_node_name] = [@bs.hostname,
                                  @bs.subnet] * ' '
        end
      end

      ## FUTURE modify this in accord with Sathya's work (JSON)
      ## TODO make these organization-level tags using subst?
      def create_server_tags(server, hostname)
        puts "Creating tags for #{server.id} with name : #{hostname}"
        tags = {}
        if @bs[:novpc]
          tags['vpc'] = 'NOVPC'
          tags['Name'] = "NOVPC:#{hostname}"
        else
          tags['Name']    = "#{@bs.vpc}.#{@bs.subnet}:#{hostname}"
          tags['fqdn']    = "#{hostname}.#{@bs.subnet}.#{@bs.vpc}.#{@bs.domain}"
          tags['vpc']     = @bs.vpc
          tags['subnet']  = @bs.subnet
        end
        tags['hosttype'] = @bs.profile if @bs[:profile]
        tags['stack']    = @bs.stack   if @bs[:stack]

        # Add any tags defined by user

        tags.merge!(@bs.mixins.tag.data.hash)
        create_tags(server.id, tags)
        print_table(tags, 'TAGS')
      end

      ## TODO move this into bs_ami_create
      def create_ami_tags(id)
        tags = {
          ## REVIEW config usage
          :Name => config[:ami_name],
          :creator => ENV['USER'],
          :created => Time.now.to_i
        }
        create_tags(id, tags)
      end

      def create_tags(entity_id, tags)
        begin
          raise ArgumentError.new('Resource ID cannot be nil') if entity_id.nil?
          puts "\nCreating tags for entity with id: #{entity_id}"
          response = connection.create_tags(entity_id, tags)
          if response.body['return']
            puts "Successfully created tags for entity: #{entity_id}"
          else
            raise Ec2Error.new
          end
        rescue Exception=>e
          ui.error("#{e.message}\nError creating tags for #{entity_id}")
        end
      end

      def create_volume(server, device, info, fqdn)
        begin
          fqdn = fqdn.nil? ? server.tags['fqdn'] : fqdn
          puts "\nCreating a new EBS volume of size #{info.size} "\
               "for #{server.id} in #{@bs.mixins.az.data}"
          volume =
            connection.volumes.create(:availability_zone => @bs.mixins.az.data,
                                      :size              => info.size.to_i)

          ## REVIEW is the call below necessary? since we are keying on
          ## The device name, this doesn't make much sense.
          ## At the same time I see where this is coming from
          #v = get_next_available_device(server) if v.nil?
          tags = {}
          tags['Name']    = info[:temp] ? device + '-' + fqdn : fqdn
          tags['subnet']  = @bs.subnet
          tags['vpc']     = @bs.vpc
          tags['device']  = device
          if info[:raid]
            tags['raid']  = 'yes'
            tags['raid_device'] = info.raid
          end

          ui.color("Waiting for volume #{volume.id} to "\
                   "be ready for server #{server.id}",
                   :magenta)
          volume.wait_for { print '.' ; ready? }

          #now create tags for the newly created volume
          create_volume_tags(volume.id, tags)
          #attach the volume to the server
          attach_volume(server, volume.id, device)
          #setting deleteontermination true for the temp volume
          if info[:temp]
            excon = connection.describe_instances({'instance-id'=>server.id})
            attrib = excon.data[:body]['reservationSet'][0]['instancesSet'][0]
            i = attrib['blockDeviceMapping'].index do |h|
              h['volumeId'] == volume.id
            end
            attributes = {
              "BlockDeviceMapping.#{i.to_s}.DeviceName"             => device,
              "BlockDeviceMapping.#{i.to_s}.Ebs.DeleteOnTermination"=> "true"
            }
            connection.modify_instance_attribute(server.id, attributes)
          end

          # return the refreshed volume
          return connection.volumes.get(volume.id)
        rescue Exception => e
          ui.error("#{e.message}\nException creating and attaching new volume")
        end
      end

      def create_volume_from_snapshot(snapshot)
        puts "\nCreating volume from snapshot : #{snapshot.description}"
        volume = connection.volumes.create( :availability_zone => @bs.mixins.az.data, :size => snapshot.volume_size,:snapshot_id => snapshot.id)
        return volume
      end

      ## See if you can abstract all tagging methods into one, since
      ## To AWS it's just a 'resource' (def tag_resource(type, id, tags))
      def create_volume_tags(volume_id, tags)
        begin
          print "\nCreating tags for #{volume_id}"
          connection.create_tags( volume_id, tags)
          print_table(tags, "CREATED TAGS FOR VOLUME: #{volume_id}")
        rescue Exception => e
          puts "\n" + e.message
          print "Exception creating tags for #{volume_id}. Continuing.."
        end
      end

      def create_spot_request
        ui.msg("\nCreating spot instance request")
        begin
          spot_request_def = { :price => @bs.mixins.price.data }
          ## REVIEW #{create_server_def}
          spot_request_def.merge!(create_server_def)
          spot_request = connection.spot_requests.create(spot_request_def)

          puts "\n#{ui.color('Request ID', :cyan)}: #{spot_request.id}"
          puts "#{ui.color('Request Type', :cyan)}: #{spot_request.request_type}"
          puts "#{ui.color('Max Price', :cyan)}: #{spot_request.price}"
          print "#{ui.color('Sent Spot Instance Request. Waiting', :magenta)}"

          #Wait for the state to become active
          spot_request.wait_for { print '.'; state == 'active' }
          server = connection.servers.get("#{spot_request.instance_id}")
          ui.color(" Spot Instance started. Server Id: #{server.id}", :magenta)
          server
        rescue
        end
      end

      # Checks if the given IP address is already being used by a running instance.
      def ip_used?(ip)
        # select builds a new Array of all the elements of the callee which return
        # true in the given block.
        connection.servers.select {|s| s.state == 'running' && s.private_ip_address == ip}.any?
      end

      def create_spot_instances(launch_group=nil, persistent=nil)
        puts "\nCreating #{@bs.number_of_nodes} spot instance(s)"
        tries = 10
        tried = 0
        begin
          tried += 1
          options = {}
          options['InstanceCount'] =
            @bs.number_of_nodes
          options['LaunchGroup'] =
            launch_group unless launch_group.nil?
          options['LaunchSpecification.SubnetId'] =
            @bs.subnet_id unless @bs[:novpc]
          options['LaunchSpecification.Placement.AvailabilityZone'] =
            @bs.mixins.az.data
          options['LaunchSpecification.KeyName'] =
            @bs[:ssh_key_name]
          options['Type'] = persistent ? 'persistent' : 'one-time'

          if @bs.mixins.volume.data[:ephemeral_available]
            ephmap = @bs.mixins.volume.data.ephemeral_available.each_with_index.map do 
              |d,i|
              {
                'VirtualName' => "ephemeral#{i}",
                'DeviceName' => d
              }
            end
          end
          block_devs = options['LaunchSpecification.BlockDeviceMapping']
          block_devs ||=
            begin
              block_devs.concat(ephmap) if block_devs && ephmap
            end

          print_table(options,'SPOT CONFIG')
          response = connection.request_spot_instances(@bs.image,
                                                       @bs.flavor,
                                                       @bs.mixins.price.data,
                                                       options)
          ui.msg("Response : #{response.inspect}")
          puts "\nRequest sent"
          request_ids = response.body['spotInstanceRequestSet'].map do |x| 
            x['spotInstanceRequestId']
          end
          sleep 10
          try = 1
          begin
            try += 1
            puts "Request ids : #{request_ids}.\nRetrieving spot requests"
            spot_requests = request_ids.map { |x| connection.spot_requests.get("#{x}")}
            raise Ec2Error.new('Nil Response') if spot_requests.nil? ||
              spot_requests.length == 0 ||
              spot_requests == [nil]
          rescue Exception => e
            if try >= tries
              print "\n\nMax tries reached. Exiting.\n\n"
              cancel_spot_requests(request_ids)
              exit 1
            else
              puts "Trying again."
              sleep 10
              retry
            end
          end
          puts "Retrieved spot requests : #{spot_requests}"

          if spot_requests.length == 0
            puts "Could not retrieve spot request. Exiting"
            exit 1
          end
          print 'Waiting for requests to be activated.'

          spot_requests.each do |req|
            req.wait_for {print'.'; state == 'active'}
          end
          sleep 10
          @bs[:servers] = []
          spot_requests.each do |req|
            begin
              server = connection.servers.get("#{req.instance_id}")
              raise Ec2Error.new('server was nil') if server.nil?
              ui.color("Spot Instance started. Server Id: #{server.id}", :magenta)
              @bs.servers << server
            rescue Exception=>e
              sleep 7
              retry
            end
          end

          @bs.servers.flatten
          @bs[:instance_ids] = @bs.servers.map { |x| x.id unless x.nil? }
        rescue Exception=>e
          ui.warn("#{e.message}\nException creating spot instances.")
          cancel_spot_requests(request_ids)
          if tried >= tries
            print "\n\nMax tries reached. Exiting.\n\n"
            exit 1
          else
            puts "Trying again."
            sleep 10
            retry
          end
        end
      end

      def cancel_spot_requests(request_ids)
        # Takes in an Array of spot request ids
        begin
          raise ArgumentError.new('Request IDs must be an Array') unless request_ids.kind_of?(Array)
          raise ArgumentError.new('Request IDs Nil') if request_ids.size == 0
          ui.msg("\nCancelling Spot Requests : #{request_ids}")
          request_ids.each { |request_id| connection.spot_requests.destroy(request_id) }
        rescue Exception=>e
          ui.warn("#{e.message}\nException cancelling spot request")
        end
      end

      def cancel_spot_request(server)
        begin
          raise ArgumentError.new('Server cannot be nil') if server.nil?
          filter = {}
          filter['instance-id'] = server.id
          response = connection.describe_spot_instance_requests(filter)
          raise Ec2Error.new("Could not determine spot request associated with server #{server.id}") if response.body['spotInstanceRequestSet'].length == 0
          request_id = response.body['spotInstanceRequestSet'][0]['spotInstanceRequestId']
          ui.msg("\nCancelling Spot Request : #{request_id}")
          unless connection.spot_requests.destroy(request_id)
            raise Ec2Error.new("Error when attempting to destroy request '#{request_id}'")
          end
        rescue Exception=>e
          ui.warn("#{e.message}\nException cancelling spot request")
        end
      end

      # Checks to see if we need to clean ourselves up (node & client exist)
      # before proceeding with server creation.
      def chef_objects_dirty?(name)
        begin
          node_exists = true
          node = Chef::Node.load(name.chomp)
        rescue Net::HTTPServerException => e
          raise unless e.response.code == '404'
          node_exists = false
          ui.msg("#{name} has no Chef node on #{Chef::Config[:chef_server_url]}")
        end
        ui.msg("#{name} Chef node exists and needs cleaning") if node_exists

        begin
          client_exists = true
          client = Chef::ApiClient.load(name.chomp)
        rescue Net::HTTPServerException => e
          raise unless e.response.code == '404'
          client_exists = false
          ui.msg("#{name} has no Chef client on #{Chef::Config[:chef_server_url]}")
        end
        ui.msg("#{name} Chef client exists and needs cleaning") if client_exists
        node_exists && client_exists
      end

      def cleanup_chef_objects(name = nil)
        puts "\nCleaning up #{name} Chef objects on #{Chef::Config[:chef_server_url]}"
        tries = 10
        begin
          node, client = get_chef_node_client(name)
          ui.color("\nDeleting #{name} client from #{Chef::Config[:chef_server_url]}", :bold)
          client.name(name)
          client.destroy
        rescue Exception=>e
          ui.warn("Exception cleaning up chef objects for #{name}\n#{e.message}")
          retry if ( tries -= 1 ) >= 0
        end

        tries = 10
        begin
          ui.color("\nDeleting #{name} node from #{Chef::Config[:chef_server_url]}", :bold)
          node.destroy
        rescue Exception=>e
          ui.warn(e.message)
          retry if ( tries -= 1 ) >= 0
        end
      end

      def create_cloudwatch_alarm(fqdn, server_id)
        alarm_config = {
          'AlarmName' =>  fqdn + "_ec2_shutdown_" + server_id,
          'Dimensions' => [
            {
              'Name' => 'InstanceId',
              'Value' => server_id
            }
          ]
        }
        alarm_config.merge!( config[:cw_alarm] )
        print_table(alarm_config, "CloudWatch Config #{fqdn}")
        cloudwatch.put_metric_alarm( alarm_config )
      end

      def progressbar(title='Progress',format='%a |%b>>%i| %p%% %t')
        # Initialize a progress bar
        @bar ||= begin
          bar = ProgressBar.create(:title => "#{title.capitalize}", :format => format)
        end
      end

      def progress(position)
        # Change the position of the progress bar
        progressbar.refresh
        progressbar.progress = position unless position.nil?
      end

      def destroy_server(server)
        begin
          unless server.nil?
            print "Terminating instance #{server.id}. Waiting for instance to terminate."
            server.destroy
            server.wait_for { print '.' ; state == 'terminated'}
            puts "\nInstance Terminated\n"
          end
        rescue Exception=>e
          ui.warn("#{e.message} Error terminating #{server.id}")
        end
      end

      def get_chef_node_client(name)
        return Chef::Node.load(name.chomp), Chef::ApiClient.load(name.chomp)
      end

      def get_next_available_device(server)
        # Returns the next available device on an instance, to which a volume can be attached.
        # E.g. if a device is already attached at /dev/sdf then it returns /dev/sdg
        # In EC2, the available devices are /dev/sdf to /dev/sdp, which the latest kernel
        # translates to /dev/xvdf to /dev/xvdp.

        # For the given server, get the server object again, with all values refreshed.
        server = connection.servers.get(server.id)

        puts "\nChecking for available devices..."
        print "\nDevices Taken: "
        server.block_device_mapping.each {|x| print "#{x['deviceName']}  "}
        device_prefix = '/dev/sd'
        ('f'..'p').each do |device_suffix|
          device_taken = false
          puts "\nChecking if #{device_prefix + device_suffix} is taken.."
          server.block_device_mapping.each do |bdm|
            device_taken = true if bdm['deviceName'] == device_prefix + device_suffix
          end
          return device_prefix + device_suffix unless device_taken
        end
        raise EbsError.new("No device available.")
      end

      def get_volumes(fqdn)
        connection.volumes.all('tag-value'=>fqdn)
      end

      def get_volume_ids(fqdn)
        volumes = get_volumes(fqdn)
        volumes.collect {|v| v.id }
      end

      def get_volume_id(fqdn)
        volume = get_volumes(fqdn)
        return volume.first.id if volume
      end

      def get_raid_volumes(volumes)
        volumes.select {|v| v.tags.has_key?('raid') }
      end

      def get_ami_with_tag(ami_name)
        begin
          puts "Searching for AMI with tag: #{ami_name}"
          image = connection.images.all({"tag-value"=>"#{ami_name}"})
          raise AMIError.new("Could not find an AMI with the tag #{ami_name}.") if image.empty?
          @bs[:image] = image.first.id
          puts "AMI NAME:#{image.first.name}" if image.first.name
        rescue Exception => e
          raise e # reraise so exception falls through
        end
      end

      def get_ami_id
        ui.msg("\nCalculating AMI ID")
        begin
          ami_info = @bs.mixins.ami.data
          if @bs[:latest]
            search_tag = [ami_info.prefix,
                          ami_info.suffix] * '*'
            ui.msg("Searching for latest ami with tag #{search_tag}")
            images = connection.images.all({'tag-value' => search_tag})
            if images.size > 0
              ui.msg("Located #{images.size} ami's " \
                     "with suffix #{ami_info.suffix}")
            else
              puts "Could not locate any ami's with tag-value : #{search_tag}"
              exit 1
            end

            # Select ami's which have the key 'created'
            latest = images.select {|img| img.tags.key?('created') }
            img = latest.sort do |x,y|
              x.tags['created'].to_i <=> y.tags['created'].to_i
            end.last
            @bs[:image]   = img.id
            @bs[:aminame] = img.name
            puts "AMI NAME:#{img.name}" if img.name

          elsif @bs[:match]
            match_profile = @bs.mixins.ami.data.match
            puts "Searching for ami matching "\
                 "#{match_profile}'s hostname"
            p = @bs.get_profile(match_profile)
            pos = p.hostname =~ /\%/
            hostname = pos ? p.hostname[0...pos] + '*' : p.hostname
            query = {
              'tag-value'=>"#{@bs.vpc}.#{@bs.subnet}:#{hostname}",
              'instance-state-name'=>'running'
            }
            servers = connection.servers.all(query)

            ui.msg("#{match_profile} : " + servers.inspect)
            if servers.size < 1
              puts "#{match_profile} not found"
              exit 1
            end

            image = connection.describe_images(
              { "ImageId" => "#{servers.first.image_id}"
              }).body['imagesSet'].first['tagSet']['Name']
            ui.msg(image.inspect)

            ## HACKS
            oldprof = @bs.profile
            @bs.profile = match_profile
            mp_suffix = @bs.get_mixin_data('ami')[:suffix]
            @bs.profile = oldprof

            amiprefix = image.split(mp_suffix).first
            ui.msg(amiprefix.inspect)
            get_ami_with_tag(amiprefix + ami_info.suffix)
          elsif @bs[:amiprefix] && (@bs[:amiprefix] != ami_info[:prefix])
            # Only want to do this section if prefix was
            # specified on command line
            if ami_info.has_key?(suffix)
              ami_name = @bs.amiprefix + ami_info.suffix
              get_ami_with_tag(ami_name)
            else
              errmsg = "No 'ami-suffix' provided in the YAML. \n"\
                       "Can't calculate an AMI ID "\
                       "with a prefix but without a suffix."
              raise YamlError.new(errmsg)
            end
          elsif ami_info[:base]
            @bs[:image] = ami_info.base
          end
        rescue Exception => e
          ui.fatal("#{ui.color(e.class.to_s, :gray, :bold)}: #{e.message}")
          case e
            when AMIError, YamlError
              # stuff could go here
            else
              puts e.backtrace
          end
          exit 1
        end
        print "AMI ID : #{@bs.image}\n"
        @bs.image
      end

      def get_elastic_ip
        # Returns a Fog::Compute::AWS::Address Object
        domain = @bs[:novpc] ? 'standard' : 'vpc'
        eip = connection.allocate_address(domain=domain)
        sleep 3
        address = connection.addresses.get(eip.body['publicIp'])
        puts "\nObtained new Elastic IP: #{address.public_ip}\n"
        return address
      end

      def get_subnet_id(filter)
        begin
          fltr = {'tag-key' => 'Name', 'tag-value' => filter}
          subnet = connection.subnets.all(fltr)
          if subnet.empty?
            ui.fatal("Could not find subnet with tag-value : #{filter}")
            exit 1
          end
          @bs[:subnet_cidr_block] = subnet.first.cidr_block
          subnet.first.subnet_id
        rescue Exception=>e
          ui.fatal("#{e.message}\nException trying to find subnet id : #{filter}")
          exit 1
        end
      end

      def get_server(fqdn)
        server = nil
        begin
          puts "Trying to locate server with tag-value : #{fqdn}"
          server = connection.servers.all({"tag-value" => "#{fqdn}"})
          raise Ec2Error.new("Could not locate server with tag value : #{fqdn}.") if server.nil?
          puts "\nLocated server."
        rescue Exception => e
          ui.fatal("#{e.message}\nException while trying to locate server")
        end
        server
      end

      def get_vpc_id
        vpc_id = nil
        begin
          vpcs = connection.vpcs.all('tag-value'=>"*#{config[:vpc]}*")
          puts vpcs.inspect if config[:verbosity] > 0
          if vpcs.length == 0
            raise Ec2Error.new('VPC not found.')
          else
            vpc_id = vpcs.first.id
            config[:vpc_id] = vpc_id
            config[:cidr_block] = vpcs.first.cidr_block
          end
        rescue Exception=>e
          ui.error("#{e.message}\nError getting vpc id.")
          exit 1
        end
        vpc_id
      end

      ## TODO rethink FQDN and move this code
      def generate_node_names
        puts "\nGenerating #{@bs.number_of_nodes} node name(s)"
        if @bs[:novpc]
          suffix = '.NOVPC'
        else
          suffix = ["",
                    @bs.subnet,
                    @bs.vpc,
                    @bs.domain] * '.'
        end

        ## Hacky... Maybe use a regex for hostname?
        ## Leaving as is for now

        if @bs.hostname.count('%') == 1
          get_available_suffixes.each do |i|
            @bs[:nodes] << @bs.hostname % i
          end
          @bs.nodes.map { |x| x << suffix }
        elsif @bs.number_of_nodes.to_i > 1
          @bs.hostname += '1%02d'
          get_available_suffixes.each do |i|
            @bs[:nodes] << @bs.hostname % i
          end
          @bs[:nodes].map { |x| x << suffix }
        else
          @bs[:nodes] << @bs.hostname + suffix
        end
      end

      def get_available_suffixes
        # Returns an array of numbers, to be used as hostname suffixes
        # E.g. [1,2,3] [4,7,9] etc..
        puts "\nCalculating available node names"
        suffixes = (1..@bs.number_of_nodes.to_i).to_a
        filter = {}
        filter['tag-value'] = [@bs.vpc,
                               @bs.subnet] * '.'
        filter['tag-value'] << ':' + @bs.hostname.split('%').first + '*'
        response = connection.servers.all(filter)
        if response.nil? || response.length == 0
          return suffixes
        else
          puts "\nTotal server(s)(running+terminated+stopped) found : #{response.length}\n"
          servers = response.select { |server| server.state == 'running' }
          puts "\nLocated #{servers.length} running server(s) #{filter['tag-value']}."
          if servers.length == 0
            return suffixes
          else
            names = servers.map {|x| x.tags['Name'].split(':')[1][2..-1].to_i%100 }
            puts "\nSuffixes taken : #{names}"
            suffixes = []
            j = 1
            until suffixes.size == @bs.number_of_nodes.to_i do
              suffixes << j unless names.include?(j)
              j += 1
            end
            puts "Calculated suffixes : #{suffixes}"
            return suffixes
          end
        end
      end

      ## FUTURE Refactor for JSON tags
      def get_servers(subnet, vpc, hostname=nil, states=['running'])
        puts "\nTrying to locate server(s)"
        filter = (hostname.dup if hostname) || "*"
        filter << '*' unless filter =~ /\*/
        tag_val = "#{vpc}.#{subnet}:#{filter}"
        servers =
          @bs.connection.servers.all({'tag-value' => tag_val}).select do |s|
          states.include?(s.state)
        end
        if servers.nil? || servers.length == 0
          raise Ec2Error.new("Could not locate server(s)"\
                             " with tag value : #{tag_val}")
        end
        puts "\nTotal server(s) found: #{servers.length}\n"
        config[:batch_size] = servers.length
        return servers
      end

      def get_snapshot(fqdn, version=nil, latest=true)
        raise ArgumentError.new("FQDN is required.") if fqdn.nil?
        snapshots = connection.snapshots.all('tag-value' => fqdn)
        if version
          final_snapshot = snapshots.select {|x| x.tags['version'] == version}.last
        else
          final_snapshot = snapshots.sort_by {|x| x.tags['created']}.last
        end
        return final_snapshot
      end

      def generate_token
        #Generate a client token for idempotent requests
        #token = ActiveSupport::SecureRandom.hex(2)
        token = 4.times.map { [*'0'..'9', *'a'..'z', *'A'..'Z'].sample }.join
        puts "\nToken : #{token}"
        token
      end

      ## TODO move this into bs_config
      def volumes_part_of_raid?(volumes)
        volumes.each do |v|
          return false unless v.tags.has_key?('raid')
        end
        return true
      end

      def msg_pair(label, value, color=:cyan)
        # Intentionally left blank. We don't want superclass to print
        # messages, because we have our own way of doing that.
      end

      ## TODO this should instead print the merged data from all levels
      def print_yaml
        puts "\n"
        #print_nested_hash(@yaml['vpc']["#{config[:vpc]}"])
        print_table( @yaml['instance']["#{config[:hosttype]}"], 'INSTANCE INFO FROM YAML')
        print_table( @yaml['region']["#{config[:region]}"], 'REGION INFO FROM YAML')
      end

      def print_mixin_data
        puts ""
        @bs.mixins.each do |m|
          print_table(m.data.hash)
        end
      end

      def print_table(hash, title = nil)
        begin
          puts "\n"
          rows = []
          hash.each_pair do |key, value|
            if value.kind_of?(Hash)
              print_table(value, title)
              next
            elsif value.kind_of?(Array)
              unless %w(ssh_keys).include?(key.to_s)
                puts "\n#{ui.color("#{key}",:magenta)} #{ui.color("#{value.join(', ')}", :bold)}"
                next
              end
            else
              unless %w(aws_access_key_id aws_secret_access_key UserData).include?(key.to_s)
                rows << [key.to_s, value.to_s]
              end
            end
          end

          if title
            puts Terminal::Table.new :rows => rows, :title => title
          else
            puts Terminal::Table.new :rows => rows
          end
        rescue Exception=>e
          ui.warn("#{e.message}\nException in print table.") unless config[:verbosity] < 1
          puts e.backtrace unless config[:verbosity] < 1
        end
      end

      def print_server_info(server, mode=:simple, title=:Information)
        puts "\n"
        return if server.nil?
        begin
          case mode.to_s
            when 'simple'
              infohash = {}
              infohash['Flavor'] =  server.flavor_id
              infohash['Image'] =  server.image_id
              infohash['VPC'] = server.tags['vpc'] if server.tags['vpc']
              infohash['Subnet'] = server.subnet_id if server.subnet_id
              infohash['Region'] =  connection.instance_variable_get(:@region)
              infohash['Availability Zone'] =  server.availability_zone
              infohash['Security Groups'] =  server.groups
              infohash['SSH Key'] =  server.key_name
              infohash['State'] =  server.state
              print_table(infohash, title)
            when 'full'
              print_server_info(server,'simple', title)
              infohash = {}
              infohash['Root Device Type'] = server.root_device_type
              infohash['Environment'] = config[:environment] || '_default'
              infohash['Run List'] = config[:run_list].join(', ') unless config[:run_list].nil?
              infohash['BlockDeviceMapping'] = server.root_device_type
              infohash['Subnet ID'] =  server.subnet_id
              infohash['Public DNS Name'] =  server.dns_name
              infohash['Public IP Address'] =  server.public_ip_address
              infohash['Private DNS Name'] =  server.private_dns_name
              infohash['Private IP Address'] =  server.private_ip_address
              print_table(infohash, title)
              print_table(server.tags, 'SERVER TAGS') unless server.tags.nil?
            else
          end
        rescue Exception => e
          ui.warn("#{e.message}\nCaught exception while printing server info.") unless config[:verbosity] < 1
          puts e.backtrace.inspect unless config[:verbosity] < 1
        end
      end

      def print_cluster_info(servers, nodes=:nil, mode=:simple)
        # Output the information in one go:
        puts "\n"
        begin
          case mode
            when :simple
              info = {}
              print_server_info(servers.first)
              servers.each { |server|  info["#{server.tags['fqdn']}"] = server.private_ip_address }
              print_table(Hash[info.sort], 'SERVER(S)')
            when :full
              serverhash = {}
              servers.length.times.to_a.each { |i| serverhash[nodes[i].to_s] = vpc_mode? ? servers[i].private_ip_address : servers[i].public_ip_address }
              print_table(serverhash, 'SERVER(S)')
              print_server_info(servers.first, 'INFO')
            else
          end
          if @bs[:novpc]
            puts "--" * 14
            puts "\tSERVER LIST\n"
            puts "--" * 14
            @bs.servers.each { |server| puts server.public_ip_address }
            puts "--" * 14
          end
        rescue Exception => e
            puts e.backtrace.inspect unless config[:verbosity] < 1
            ui.warn('Caught exception while printing cluster info. Ignoring and Proceeding')
        end
      end

      def print_volume_info(volume_id)
        hash = {}
        begin
          vol = connection.describe_volumes({'volume-id'=>"#{volume_id}"}).body['volumeSet'].first
          vol.each do |k,v|
            hash[k] = v unless k == 'attachmentSet' || k == 'tagSet'
          end
          print_table(hash, 'VOLUME INFO')
          print_table(vol['tagSet'],'VOLUME INFO')
        rescue
          print "\nException while trying to print volume info. Continuing.."
        end
      end

      def print_nested_hash(hash)
        ap hash, indent: -2, index: false
      end

      def print_subnet_info(subnet_id)
        begin
          subnet = connection.describe_subnets({'subnet-id'=>"#{subnet_id}"}).body['subnetSet'].first
          print_table(subnet, 'SUBNET INFO')
        rescue Exception=>e
          ui.warn("#{e.message}\nException while trying to print subnet info.") if config[:verbosity] > 0
        end
      end

      def print_time_taken
        ## TODO get config[:start_time] somewhere
        # end_time = Time.now.to_i
        # time_elapsed = end_time - config[:start_time]
        # mins = time_elapsed/60
        # print "\nTime elapsed ~ #{mins} minutes\n"
      end

      def print_messages
        puts
        ui.print_messages
        puts
      end

      def same_type?(servers)
        hosttype = servers.first.tags['hosttype']
        servers.each do |x|
          if x.tags['hosttype'] != hosttype
            return false
          end
        end
        return true
      end

      ## REVIEW superfluous
      def vpc_mode?
        @bs[:novpc].nil?
      end

      def locate_config_value(key)
        key = key.to_sym
        config[key] || Chef::Config[:knife][key]
      end
    end
  end
end
