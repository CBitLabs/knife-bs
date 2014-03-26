require 'chef/knife/bs_base'

class Chef
  class Knife
    class BsServerShow < Knife

      include Knife::BsBase
      banner "
############################################################################
----------------------------------------------------------------------------
knife bs server show VPC.SUBNET HOSTNAME (options)
----------------------------------------------------------------------------

Show info about (running) node

Usage:
    knife bs server show ame1.ops rs101

############################################################################
"
      def run
        $stdout.sync = true

        build_config(name_args)

        ui.msg("Searching for server : #{@bs.fqdn}")
        instance_id = connection.servers.collect {|server| server.id if server.tags['fqdn'] == fqdn}.compact.first
        @instance_list = connection.describe_instances({'instance-id'=> instance_id})

        unless @instance_list.body['reservationSet'].size == 0
          print_nested_hash(@instance_list.body['reservationSet'].first['instancesSet'].first)
        else
          ui.msg(connection.inspect) unless config[:verbosity] < 1
          ui.msg(@instance_list.inspect) unless config[:verbosity] < 1
          ui.error('Sorry. Your search returned no results.')
        end
      end

      def build_config(name_args)
        if name_args.size < 2
          show_usage
          exit 1
        end
        config[:hostname]             = name_args.pop
        config[:vpc], config[:subnet] = name_args.pop
        base_config
      end
    end
  end
end
