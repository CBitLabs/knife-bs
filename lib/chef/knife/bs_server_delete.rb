require 'chef/knife/bs_base'
require 'chef/knife/ec2_server_delete'
require 'chef/node'
require 'chef/api_client'
require 'parallel'
require 'chef/knife/ec2_server_create'

class Chef
  class Knife
    class BsServerDelete < Knife::Ec2ServerCreate

      include Knife::BsBase

      attr_accessor :servers

      banner "
############################################################################
----------------------------------------------------------------------------
knife bs server delete VPC.SUBNET FILTER (options)
----------------------------------------------------------------------------

Terminate instances in EC2.
Usage:
To terminate master of dev:
    knife bs server delete ame1.dev ms101
To terminate all slaves of dev:
    knife bs server delete ame1.dev rs*
To terminate all half-baked servers (improperly tagged/unusable) of dev:
    knife bs server delete ame1.dev --spare
To terminate all half-baked servers (improperly tagged/unusable) on all subnets
    knife bs server delete --spare
############################################################################
"
      attr_reader :server

      option :dry_run,
             :long => "--dry_run",
             :description => "Don't really run, just use mock calls"
      option :spare,
             :long => "--spare",
             :description => "Kill all spares that optionally match a subnet and filter"

      def run
        $stdout.sync = true
        config[:verbosity] = 2 if config[:only_config]

        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end

        build_config(name_args)

        #
        # Find Servers
        #
        ## FUTURE adapt this to Sathya's changes (tags are going to change)
        if @bs[:spare]
          ## - Also we could use the name_args, but since we're looking
          ## for machines that are improperly tagged this is likely to
          ## not work the way you think. Ask Issa/Isaac?
          @servers = connection.servers.all({'instance-state-name'=>
                                             'running'}).select do |server|
            server.tags.empty? || server.tags['Name'].nil?
          end
        else
          @servers = get_servers(@bs.subnet, @bs.vpc, @bs.delete_filter,
                                 states=['running', 'stopped'])
        end
        exit 1 if @servers.size == 0

        #
        # Print Server Info
        #
        begin
          info = {}
          info['flavor']    = @servers.first.flavor_id
          info['vpc']       = @servers.first.tags['vpc']
          info['cluster']   = @servers.first.tags['Cluster']
          info['subnet']    = @servers.first.subnet_id
          info['created']   = @servers.first.created_at
          info['image Id']  = @servers.first.image_id
          info['state']     = @servers.first.state
          print_table( info, 'SERVER(S)')
          info = {}
          @servers.each { |server|  info["#{server.tags['fqdn']}"]=server.private_ip_address }
          print_table( info, 'SERVERS')
        rescue Exception=>e
          puts e.message
        end

        #
        # Confirm deletion of server(s)
        #
        ui.confirm('Delete server(s)')
        if @servers.length > 1
          ui.confirm('Really terminate server(s)')
        end

        #
        # Terminate the server(s)
        #
        Parallel.map(@servers.length.times.to_a, :in_threads => config[:batch_size].to_i) do |num|
          begin
            print "\nWaiting for #{@servers[num].tags['fqdn']} to terminate"
            @servers[num].destroy
            @servers[num].wait_for { print '.'; state=='terminated'}
            puts "\nTerminated #{@servers[num].private_ip_address} "
          rescue
            ui.warn("\nException while deleting server #{@servers[num].private_ip_address}. Ignoring and proceeding..\n")
          end
        end

        #
        # Delete the node and client from Chef Server
        # 
        ## REVIEW this will fail for --spare as it has no tags
        Parallel.map(@servers.length.times.to_a,
                     :in_threads => config[:batch_size].to_i) do |num|
          begin
            ui.msg(ui.color("\nDeleting the associated client and node from"\
                            " Chef Server for #{@servers[num].tags['fqdn']}",
                            :bold))
            fqdn = @servers[num].tags['fqdn'].split('.')
            node_name = fqdn[0] + '.' + fqdn[1]
            client = Chef::ApiClient.new
            client.name(node_name)
            client.destroy unless client.nil?
            node = Chef::Node.load(node_name)
            node.destroy unless node.nil?
          rescue Exception => e
          end
        end

        print_messages
        puts "\nDone!\n"
      end
      def build_config(name_args)
        # Override Fog timeout from 10min to 20
        Fog.timeout = 1200
        # Killing spares doesn't require subnet/vpc and filter
        unless config[:spare]
          if name_args.size != 2
            show_usage
            exit 1
          end
        end
        name_args.reverse!
        config[:vpc], config[:subnet] = name_args.pop.split('.')
        config[:delete_filter] = name_args.pop unless name_args.empty?
        base_config
      end
    end
  end
end
