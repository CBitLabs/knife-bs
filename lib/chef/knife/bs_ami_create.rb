require 'chef/knife/bs_base'
require 'chef/knife/bootstrap'
require 'chef/knife/ec2_server_create'
require 'time'
require 'chef/knife/ec2_base'

class Chef
  class Knife
    class BsAmiCreate < Knife::Ec2ServerCreate

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
knife bs ami create VPC.SUBNET AMITYPE (options)
----------------------------------------------------------------------------

Create an AMI. AMITYPE corresponds to a chef recipe to be run.
  TODO: map out recipes to types in YAML!

Usage:
To create a master ami on ame1.ops:
    knife bs ami create ame1.ops master
############################################################################
"
      option :identity_file,
             :short => '-i IDENTITY_FILE',
             :long => '--identity-file IDENTITY_FILE',
             :description => 'The SSH identity file used for authentication'

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

      option :no_spot,
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

      # OK
      def run
        $stdout.sync = true
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end

        build_config(name_args)
        amix = @bs.mixins.ami.data

        print_config

        ## TODO add more validation
        validate

        get_ami_name
        ami_name_taken?

        exit 1 if @bs[:only_config]

        #
        # Create instance. By default a spot instance is created.
        # It can be overridden via command line parameter.
        ## FUTURE or by deployment config

        ## REVIEW maybe reuse parts of bs_server_create
        server = nil
        if @bs[:no_spot]
          begin
            server = connection.servers.create(create_server_def)
            print "#{amix.ami_type} : Creating an on-demand server. Waiting"
            server.wait_for { print '.'; ready? }
          rescue Exception=>e
            ui.error("#{e.message}\n#{amix.ami_type} : Exception "\
                     "while creating server. Destroying.")
            destroy_server(server)
            exit 1
          end
        else
          begin
            puts "\n#{amix.ami_type}: Requesting spot instance"
            @bs[:number_of_nodes] = 1
            ## GOOD/OK until here
            servers, _ = create_spot_instances
            server = servers.first
          rescue SystemExit, Interrupt, Exception=>e
            ui.error("#{e.message}")
            cancel_spot_request(server)
            exit 1
          end
        end

        #
        #Create tags
        #
        puts "\n#{amix.ami_type}: "\
             "#{ui.color('Creating Server Tags', :magenta)}"
        create_server_tags(server, @bs[:chef_node_name])

        #
        # Bootstrap them with role specified in YAML
        #
        print "\n#{amix.ami_type}: Waiting for SSHD.."
        print('.') until tcp_test_ssh(server.private_ip_address,
                                      config[:ssh_port]) {
          sleep @initial_sleep_delay ||= (vpc_mode? ? 40 : 10)
          puts("#{amix.ami_type} ready")
        }
        $stdout.flush
        tries = 5
        begin
          bootstrap_for_linux_node(server, server.private_ip_address).run
        rescue Exception=>e
          ui.error("#{e.message}\n#{amix.ami_type}: Exception "\
                   "while bootstrapping server. Retrying.")
          if (tries -= 1) <= 0
            print "\n\n#{amix.ami_type}: Max tries reached. "\
                  "Deleting server and exiting. AMI Creation failed.\n\n"
            # destroy_server(server)
            exit 1
          else
            retry
          end
        end

        # Clean up the image.
        ui.msg("#{amix.ami_type}:  #{ui.color('Cleaning up', :bold)}")
        clean_up(server)

        # Create AMI
        print "#{amix.ami_type}:  #{ui.color("Creating AMI", :bold)}"
        ami = connection.create_image(server.id, config[:ami_name],
                                      no_reboot = true,
                                      server.block_device_mapping)
        id = ami.body['imageId']
        puts "\n#{amix.ami_type}: Waiting for #{id} to be available"
        begin
          image = connection.images.get(id)
          image.wait_for { print '.'; state == 'available'}
        rescue Exception=>e
          retry
        end

        # Create tags
        create_ami_tags( id )

        # Terminate instance
        cancel_spot_request(server)
        destroy_server(server)

        # Delete the node and client from Chef
        cleanup_chef_objects( config[:chef_node_name] )

        print_time_taken
        print "\n#{amix.ami_type}: #{ui.color("CREATED #{amix.ami_type} AMI\nID : #{id}\nAMI : #{config[:ami_name]}", :bold)}\n"
        #print some info
        begin
          print_table(connection.describe_images('image-id'=>"#{id}").body['imagesSet'].first, 'AMI INFO')
        rescue
        end

        print_messages
        ui.msg("\n#{amix.ami_type}: Done!\n")
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
        @bs[:hostname]               = @bs.hosttype
        @bs[:chef_node_name]         = [@bs.hostname,
                                        @bs.subnet,
                                        @bs.start_time].join('.')
        @bs[:fqdn]                 ||= [@bs.hostname, 
                                        @bs.subnet,
                                        @bs.vpc,
                                        @bs.domain].join('.')
        @bs[:image]                  = amix.base
        Chef::Config[:knife][:image] = @bs.image

        runlist = []
        runlist << "recipe[#{amix[:cookbook]}]"                   if amix[:cookbook]
        runlist << "recipe[#{amix[:cookbook]}::#{amix[:recipe]}]" if amix[:recipe]
        @bs[:run_list] = runlist.concat(@bs[:run_list])
      end

      def get_ami_name
        time = Time.new
        name = [ENV['USER'],
                [time.year.to_s,
                 time.month.to_s,
                 time.day.to_s,
                 time.hour.to_s,
                 time.min.to_s].join('.')].join('-')

        if @bs[:git_hash]
          name += '-' + @bs.git_hash
        else
          begin
            # Try to calculate git hash from directory where YAML lives
            dir = File.dirname(Chef::Config[:knife][:yaml])
            @bs[:git_hash] = %x[cd #{dir}; git rev-parse --short HEAD].chomp
            if $?.success?
              name += '-' + @bs.git_hash
            end
          rescue Exception=>e
            ui.warn("#{e.message}\nCould not calculate git hash")
          end
        end
        # Append ami-type to the end
        # name += '-' + @bs.mixins.ami.data.ami_type
        print_table({:AMI_NAME=>name},'AMI')
        @bs.ami_name = name
      end

      def ami_name_taken?
        puts "Checking if AMI Name is taken"
        begin
          images = connection.images.all({'tag-value'=>
                                           "*#{@bs.mixins.ami.data.ami_type}*"})
          if images.size > 0
            images.each do |x|
              if x.tags['Name'] == @bs.ami_name
                puts "#{@bs.ami_name} is already taken."
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
