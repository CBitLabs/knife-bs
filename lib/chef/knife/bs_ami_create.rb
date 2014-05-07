require 'time'
require 'chef/knife/bs_base'
require 'chef/knife/ec2_base'
require 'chef/knife/bootstrap'
require 'chef/knife/bs_server_create'

class Chef
  class Knife
    class BsAmiCreate < Chef::Knife::BsServerCreate

      include Knife::BsBase

      deps do
        require 'fog'
        require 'readline'
        require 'chef/node'
        require 'chef/client'
        require 'chef/api_client'
        require 'chef/json_compat'
        Chef::Knife::Bootstrap.load_deps
      end


      banner "
############################################################################
----------------------------------------------------------------------------
knife bs ami create VPC.SUBNET PROFILE (options)
----------------------------------------------------------------------------

Create an AMI. PROFILE corresponds with a chef recipe to be run.

Usage:
To create a master ami on ame1.ops:
    knife bs ami create ame1.ops master
############################################################################
"
      option :identity_file,
             :short => '-i IDENTITY_FILE',
             :long => '--identity-file IDENTITY_FILE',
             :description => 'The SSH identity file used for authentication'

      option :bootstrap_version,
             :long => '--bootstrap-version VERSION',
             :description => 'The version of Chef to install',
             :proc => proc { |v| Chef::Config[:knife][:bootstrap_version] = v }

      option :run_list,
             :short => '-r RUN_LIST',
             :long => '--run-list RUN_LIST',
             :description => 'Comma separated list of roles/recipes to apply',
             :proc => lambda { |o| o.split(/[\s,]+/) }

      option :git_hash,
             :short => '-g GIT_HASH',
             :long => '--git-hash GIT_HASH',
             :description => 'The latest GIT HASH'

      option :dry_run,
             :long => '--dry_run',
             :description => "Don't really run, just use mock calls"

      option :nospot,
             :long => '--nospot',
             :description => 'Use an on-demand instance instead of spot'

      option :price,
             :short => '-p PRICE',
             :long => '--spot-price PRICE',
             :description => 'The max spot price to be set',
             :default => 0.5

      option :flavor,
             :short => "-f FLAVOR",
             :long => "--flavor FLAVOR",
             :description => "Instance Type. Default : m3.xlarge",
             :default => 'm3.xlarge'

      option :only_config,
             :long => '--dryrun',
             :description => 'Print config and exit'

      def run
        $stdout.sync = true
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end

        build_config(name_args)
        print_config
        ui.msg("Calculated AMI: #{@bs.mixins.ami.ami_name}")

        validate

        ami_name_taken?

        exit 1 if @bs[:only_config]
        build_ami
      end

      def build_config(name_args)
        ui.msg('Building config for AMI creation')
        # It should always be in the form of VPC.SUBNET PROFILE
        if name_args.size == 2
          config[:vpc], config[:subnet] = name_args[0].split('.')
          config[:profile] = name_args[1]
        else
          ui.fatal('Please provide the VPC.SUBNET and PROFILE arguments')
          #show_usage
          exit 1
        end
        # Basic configuration; loads mixins
        base_config

        amix = @bs.mixins.ami.data
        # Node configuration
        ## REVIEW using profile as the hostname
        @bs[:hostname]               = @bs.profile
        @bs[:chef_node_name]         = [@bs.hostname,
                                        @bs.subnet,
                                        @bs.start_time].join('.')
        @bs[:fqdn]                 ||= [@bs.hostname,
                                        @bs.subnet,
                                        @bs.vpc,
                                        @bs.domain].join('.')
        @bs[:image]                  = amix.base
        Chef::Config[:knife][:image] = @bs.image

        @bs[:number_of_nodes] = 1
        @bs[:batch_size] ||= @bs[:number_of_nodes]
        @bs[:associations] = {}
        @bs[:nodes] = []
        generate_node_names
        ui.msg(@bs.nodes)

        @bs.mixins.price.configure do |pricemix|
          pricemix.data = @bs[:price] if @bs[:price]
          @bs[:create_spot] = !!pricemix.data
        end

        runlist = []
        runlist << "recipe[#{amix[:cookbook]}]" if amix[:cookbook]
        runlist << "recipe[#{amix[:cookbook]}::"\
                   "#{amix[:recipe]}]"          if amix[:recipe]
        @bs[:run_list] = @bs[:run_list] ?
                           runlist.concat(@bs[:run_list]) : runlist
        ## TODO do this by default for all settings -> set them in
        ## config[]. In order for this to work need to verify that there
        ## are no overlapping top level configuration options
        config[:run_list] = @bs[:run_list]

        if @bs[:git_hash]
          amix[:git_hash] = '-' + @bs.git_hash
        else
          begin
            # Try to calculate git hash from directory where YAML lives
            dir = File.dirname(Chef::Config[:knife][:yaml])
            amix[:git_hash] = '-' + %x[cd #{dir}; git rev-parse --short HEAD].chomp
            amix[:git_hash] = nil unless $?.success?
          rescue Exception=>e
            ui.warn("#{e.message}\nCould not calculate git hash")
          end
        end

        @bs.mixins.tag.eval(binding)
        @bs[:ami_name] ||= @bs.mixins.ami.ami_name
      end

      def validate
        ## TODO add validation
      end

      def build_ami
        #
        # Create instance. By default a spot instance is created.
        # It can be overridden via command line parameter.

        amix = @bs.mixins.ami
        create_servers
        server = @bs.servers.first
        print_dns_info
        wait_until_ready
        tag_servers
        @bs.associations.first[1]['chef_node_name'] = @bs.chef_node_name
        check_ssh
        bootstrap_servers

        # Clean up the image.
        ui.msg("#{@bs.profile}:  #{ui.color('Cleaning up', :bold)}")
        ## TODO see if you can avoid having to run all of the
        ## post_bootstrap stuff
        @bs.mixins.ami.clean(server)
        post_bootstrap

        # Create AMI
        print "#{@bs.profile}:  #{ui.color("Creating AMI", :bold)}"
        ami = connection.create_image(server.id, @bs[:ami_name],
                                      no_reboot = true,
                                      server.block_device_mapping)
        id = ami.body['imageId']
        puts "\n#{@bs.profile}: Waiting for #{id} to be available"
        begin
          image = connection.images.get(id)
          image.wait_for { print '.'; state == 'available'}
        rescue Exception=>e
          retry
        end

        # Create tags
        create_tags(id, @bs.mixins.ami.tags)

        # Terminate instance
        cancel_spot_request(server)
        destroy_server(server)

        # Delete the node and client from Chef
        cleanup_chef_objects( @bs.chef_node_name )

        print_time_taken
        print "#{@bs.profile}:"
        ui.msg(ui.color(
                "CREATED #{@bs.profile} AMI\n"\
                "ID : #{id}\n"\
                "AMI : #{config[:ami_name]}",
                :bold))
        #print some info
        begin
          print_table(
            connection.describe_images(
            'image-id'=>"#{id}").body['imagesSet'].first, 'AMI INFO')
        ## REVIEW blank rescue
        rescue
        end

        print_messages
        ui.msg("\n#{@bs.profile}: Done!\n")
      end

      def ami_name_taken?
        ui.msg("Checking if AMI Name is taken")
        begin
          images = connection.images.all({'tag-value'=>
                                           "*#{@bs.mixins.ami.suffix}*"})
          if images.size > 0
            images.each do |x|
              if x.tags['Name'] == @bs.mixins.ami.ami_name
                puts "#{@bs.mixins.ami.ami_name} is already taken."
                exit 1
              end
            end
          end
        rescue Exception=>e
          ui.error("#{e.message}\nError calculating AMI Name.")
          exit 1
        end
      end

    end
  end
end
