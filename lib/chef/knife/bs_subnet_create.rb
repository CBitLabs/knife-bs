require 'fog'
require 'chef/knife/ec2_base'

class Chef
  class Knife
    class BsSubnetCreate < Ec2ServerCreate

      include Knife::BsBase

      banner "
############################################################################
----------------------------------------------------------------------------
knife bs subnet create VPC.SUBNET (options)
----------------------------------------------------------------------------

Create a new subnet. The subnet IP cidr should be defined in the YAML, in
the vpc->ame1->lans-> section.

Example:
  vpc:
    ame1:
      az: us-east-1c
      route-tbl: rtb-1a2b3c4
      lans:
        dev:
          net: 2
        dev2:
          net: 3
          az: us-east-1d
          route-tbl: rtb-a1b2c3d

Usage:
To create dev subnet:
    knife bs subnet create ame1.dev
############################################################################
"

      option :only_config,
        :short => '-q',
        :description => 'Only print config and exit.'

      option :route_table,
        :short => '-r ROUTE_TABLE',
        :long => '--route-table ROUTE_TABLE',
        :description => 'Associate this route table with the subnet being created'

      option :ip,
        :short => '-i IP',
        :long => '--ip IP',
        :description => 'Number for the IP block of the subnet being created, i.e. 16'

      def run
        $stdout.sync = true

        show_usage and exit 1 unless name_args.length == 1
        build_subnet_config(name_args)
        validate!

        create_subnet
        associate_route_table
        tag_subnet

        # Done
        subnet_info = connection.describe_subnets({'subnet-id' => @subnet.subnet_id}).body['subnetSet'].first
        print_table(subnet_info, 'SUBNET INFO')
        print_messages
        print "#{ui.color("\nSubnet ready!\n\n", :bold)}"
      end

      # Build the config hash from YAML unless options have been specified
      # via CLI option.
      def build_subnet_config(name_args)
        load_yaml
        get_vpc_id
        config[:vpc], config[:subnet] = name_args[0].split('.')
        begin
          config[:availability_zone] ||= get_az
          config[:route_table]       ||= get_route_table
          config[:ip]                ||= get_ip
        rescue YamlError => e
          ui.fatal(e.message)
          exit 1
        end
      end

      def validate!
        # check subnet tags and cidr_block for conflicts
        name_tag = "#{config[:vpc]}.#{config[:subnet]}"
        cidr = config[:cidr_block].gsub('0.0/16', "#{config[:ip]}.0/24")
        matches = connection.subnets.all.select do |snet|
          (snet.tag_set['Name'] == name_tag) || (snet.cidr_block == cidr)
        end
        unless matches.size == 0
          ui.fatal("#{matches.size} subnet(s) matched against given config!")
          exit 1 
        end
      end

      def create_subnet
        ui.msg("Creating #{config[:subnet]} subnet in #{config[:vpc]} VPC in #{config[:availability_zone]}")
        begin
          @subnet = connection.subnets.new(create_subnet_def)
          raise RuntimeError.new("Error creating subnet!") unless @subnet
          @subnet.save
          print "\nWaiting for subnet to be available..."
          sleep 5
          @subnet.wait_for { print '.' ; state == 'available'}
        rescue Exception => e
          ui.fatal("#{e.message}\nCould not create #{config[:subnet]} subnet.")
          connection.subnets.destroy(@subnet.subnet_id)
          exit 1
        end
      end

      def associate_route_table
        subnet_id = @subnet.subnet_id
        vpc_id = config[:vpc_id]
        puts "\nAssociating route table for #{subnet_id}"
        begin
          response = connection.associate_route_table(config[:route_table], subnet_id)
          config[:rtbassoc] = response.body['associationId']
        rescue Exception => e
          ui.error("#{e.message}\nException associating route table.")
        end
      end

      def tag_subnet
        vpc = config[:vpc]
        subnet = config[:subnet]
        id = @subnet.subnet_id
        puts "\nCreating subnet tags for #{id}"
        tags = {}
        tags['Name'] = "#{vpc}.#{subnet}"
        k1 = "meta:subnet:#{vpc}.#{subnet}-1"
        v1 = '{"version": 1, "related": {"meta:route-assoc:' + "#{vpc}.#{subnet}-1\": "
        v1 += '{"version": 1, "id": "' + "#{config[:rtbassoc]}\"}}}"
        tags[k1] = v1

        k2 = "yconf:#{vpc}.#{subnet}-1:0"
        v2 = 'md5 of something'
        tags[k2] = v2
        create_tags(id, tags)
      end

      def create_subnet_def
        puts "\nCreating config for #{config[:subnet]} subnet"
        cidr = config[:cidr_block].gsub('0.0/16', "#{config[:ip]}.0/24")
        subnet_def = {
          :vpc_id => config[:vpc_id],
          :cidr_block => cidr,
          :availability_zone => config[:availability_zone]
        }
        print_table(subnet_def, 'SUBNET DEF')
        subnet_def
      end

      def get_az
        errmsg  = "No availability zone specified in the YAML for the VPC #{config[:vpc]}"
        errmsg += " or subnet #{config[:subnet]}"
        get_subnet_key_from_yaml('az', errmsg)
      end

      def get_route_table
        errmsg  = "No route table defined in the YAML for either VPC #{config[:vpc]}"
        errmsg += " or subnet #{config[:subnet]}"
        get_subnet_key_from_yaml('route-tbl', errmsg)
      end

      def get_ip
        errmsg = "No IP set in YAML for subnet #{config[:subnet]} in VPC #{config[:vpc]}"
        get_subnet_key_from_yaml('net', errmsg, check_vpc = false)
      end

      # Attempts to retrieve a given key from the YAML
      # Arguments:
      # - key: key to check for in YAML
      # - msg: Error message to return if not found
      # - check_vpc: Whether or not to check for a default VPC value
      def get_subnet_key_from_yaml(key, msg, check_vpc = true)
        vpc    = config[:vpc]
        subnet = config[:subnet]
        unless @yaml['vpc'][vpc]['lans'].has_key?(subnet)
          raise YamlError.new("No definition for #{subnet} subnet in YAML!")
        end
        if @yaml['vpc'][vpc]['lans'][subnet].has_key?(key)
          return @yaml['vpc'][vpc]['lans'][subnet][key]
        end

        if check_vpc
          return @yaml['vpc'][vpc][key] if @yaml['vpc'][vpc].has_key?(key)
        end
        # Haven't found it, raise an error 
        raise YamlError.new(msg)
      end
    end
  end
end
