require 'chef/knife/bs_base'
require 'chef/knife/ec2_server_list'

class Chef
  class Knife
    class BsServerList < Knife::Ec2ServerList

      include Knife::BsBase
      banner "
############################################################################
----------------------------------------------------------------------------
knife bs server list (VPC.SUBNET|ENVIRONMENT) [FILTER] (options)
----------------------------------------------------------------------------

List running servers

Usage:
To list all instances running in dev:
    knife bs server list ame1.dev

To list slaves in production:
    knife bs server list production rs
############################################################################
"
      option :as_env,
             :short => "-e",
             :long => "--env",
             :description => "Treat first argument as environment instead of subnet"

      def run
        ## TODO add more options for listing, like:
        ## Stack, profile and subnet/vpc glob
        # Put Fog into mock mode if --dryrun
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end

        $stdout.sync = true

        build_config(name_args)

        # Find Servers
        @bs[:servers] = get_servers(@bs.subnet, @bs.vpc, nil,
                                    ['running', 'stopped'])
        exit 1 if @bs.servers.size == 0

        print_server_table
      end

      def print_server_table
        headings = [
          ui.color('FQDN', :bold),
          ui.color('Private IP', :bold),
          ui.color('Flavor', :bold),
          ui.color('AZ', :bold),
          ui.color('State', :bold)
        ].flatten.compact

        server_list = []
        @bs.servers.each do |server|
          row = []
          row << server.tags['fqdn'].to_s
          row << server.private_ip_address.to_s
          row << ui.color(server.flavor_id.to_s, fcolor(server.flavor_id.to_s))
          row << ui.color(server.availability_zone.to_s,
                          azcolor(server.availability_zone.to_s))
          row << ui.color(server.state.to_s.downcase,
                          scolor(server.state.to_s.downcase))
          server_list << row
        end

        table_def = {
          :title => 'SERVER(S)',
          :headings => headings,
          :rows => server_list,
        }
        puts Terminal::Table.new(table_def)
      end

      def build_config(name_args)
        # absolute wildcard filter if nothing specified
        name_args[1] = '*' if name_args.size == 1
        if name_args.size != 2
          show_usage
          exit 1
        end
        name_args.reverse!
        unless config[:as_env]
          config[:vpc], config[:subnet] = name_args.pop.split('.')
        else
          config[:environment] = name_args.pop
        end

        config[:filter] = name_args.pop

        base_config

      end

      def fcolor(flavor)
        case flavor
        when /\.xlarge$/
          fcolor = :red
        when /\.large$/
          fcolor = :green
        when /\.medium$/
          fcolor = :cyan
        when /\.small$/
          fcolor = :magenta
        when 't1.micro'
          fcolor = :blue
        else
          fcolor = :white
        end
      end

      def azcolor(az)
        case az
        when /a$/
          color = :blue
        when /b$/
          color = :green
        when /c$/
          color = :red
        when /d$/
          color = :magenta
        else
          color = :cyan
        end
      end

      def scolor(state)
        case state
        when 'shutting-down', 'terminated', 'stopping', 'stopped'
          scolor = :red
        when 'pending'
          scolor = :yellow
        else
          scolor = :green
        end
      end
    end
  end
end
