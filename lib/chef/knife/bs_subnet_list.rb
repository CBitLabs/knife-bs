require 'chef/knife/bs_base'
require 'chef/knife/ec2_server_list'

class Chef
  class Knife
    class BsSubnetList < Knife::Ec2ServerList

      include Knife::BsBase
      banner "
############################################################################
----------------------------------------------------------------------------
knife bs subnet list VPC [FILTER] (options)
----------------------------------------------------------------------------

List subnets

Usage:
To list all subnets in VPC 'ame1':
    knife bs subnet list ame1

To list subnets in 'ame1' starting with 'dev':
    knife bs subnet list ame1 dev
############################################################################

OPTIONS:
"
    option :sort_by,
      :long => '--sortby COL',
      :description => 'Column to sort table by. Choices: name, cidr, ips, vpc, az, state'

      def run
        $stdout.sync = true
        # Put Fog into mock mode if --dryrun
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end

        build_config(name_args)

        subnets = get_subnets
        exit 1 if subnets.size == 0

        print_subnet_table(subnets)
      end

      def build_config(name_args)
        name_args[1] = '*' if name_args.size == 1
        if name_args.size != 2
          show_usage
          exit 1
        end

        if config[:sort_by]
          if %w[name cidr ips vpc az state].include?(config[:sort_by])
            @sortcol = config[:sort_by]
          else
            ui.error("Invalid column '#{config[:sort_by]}' "\
                     "to sort by, not sorting")
            @sortcol = nil
          end
        else
          @sortcol = nil
        end

        @vpc = name_args[0].dup
        @pattern = name_args[1].dup
        base_config
      end

      def get_subnets
        begin
          puts "\nTrying to locates subnet(s)"
          @pattern << '*' unless @pattern =~ /\*/
          filter = {}
          # tag 'Name' => ame1.dev
          filter['tag-value'] = "#{@vpc}.#{@pattern}"
          subnets = connection.subnets.all(filter)
          unless subnets.nil? || subnets.length == 0
            if @sortcol
              return sort_subnets(subnets)
            else
              return subnets
            end
          else
            raise "Could not locate subnet(s) with tag value : #{filter['tag-value']}"
          end
        rescue Exception => e
          ui.warn("#{e.message}\nError getting subnets for #{@vpc}, #{@pattern}")
          exit 1
        end
      end

      def sort_subnets(subnets)
        case @sortcol
        when 'name';  subnets.sort_by! {|s| s.tag_set['Name']}
        when 'cidr';  subnets.sort_by! {|s| s.cidr_block}
        when 'ips';   subnets.sort_by! {|s| s.available_ip_address_count.to_i}
        when 'vpc';   subnets.sort_by! {|s| vpc_id_to_name(subnet.vpc_id) }
        when 'az';    subnets.sort_by! {|s| s.availability_zone}
        when 'state'; subnets.sort_by! {|s| s.state}
        end
        return subnets
      end

      def print_subnet_table(subnets)
        headings = [
          ui.color('Name', :bold),
          ui.color('CIDR', :bold),
          ui.color('IPs', :bold),
          ui.color('VPC', :bold),
          ui.color('AZ', :bold),
          ui.color('State', :bold)
        ].flatten.compact

        subnet_list = []
        subnets.each do |subnet|
          row = []
          row << subnet.tag_set['Name'].gsub("#{@vpc}.", '').to_s
          row << subnet.cidr_block.to_s
          row << ui.color(subnet.available_ip_address_count.to_s,
                          ips_color(subnet.available_ip_address_count.to_i))
          row << vpc_id_to_name(subnet.vpc_id)
          row << ui.color(subnet.availability_zone.to_s,
                          azcolor(subnet.availability_zone.to_s))
          row << ui.color(subnet.state.to_s.downcase,
                          scolor(subnet.state.to_s.downcase))
          subnet_list << row
        end

        table_def = {
          :title => 'SUBNET(S)',
          :headings => headings,
          :rows => subnet_list,
        }
        puts Terminal::Table.new(table_def)
      end

      def vpc_id_to_name(vpc_id)
        connection.vpcs.get(vpc_id).tags['Name']
      end

      def ips_color(ips)
        if ips <= 25
          ips_color = :red
        elsif ips > 25 && ips <= 100
          ips_color = :magenta
        elsif ips > 100 && ips <= 150
          ips_color = :cyan
        else
          ips_color = :green
        end
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
