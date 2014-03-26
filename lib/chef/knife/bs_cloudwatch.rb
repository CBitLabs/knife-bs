require 'chef/knife/bs_base'
require 'parallel'
require 'fog'

class Chef
  class Knife
    class BsCloudwatch < Knife::Ec2ServerCreate

      include Knife::BsBase
      banner "
############################################################################
----------------------------------------------------------------------------
knife bs cloudwatch VPC.SUBNET HOSTTYPE (options)
----------------------------------------------------------------------------

Set up Amazon CloudWatch on any instance.Set up the config in the yaml, and
add the following lines to any HOST TYPE.
Example:
cloudwatch:
    metric: AWS/EC2 CPUUtilization
    operations: Maximum < 2
    period: 300 24

Usage:
To apply CloudWatch to all slaves
    knife bs cloudwatch ame1.dev slave
############################################################################
"

      option :only_config,
             :long => '--dryrun',
             :description => 'Print config and exit'

      def run
        #
        # Put Fog into mock mode if --dry_run
        #
        if config[:dry_run]
          Fog.mock!
          Fog::Mock.delay = 0
        end

        $stdout.sync = true

        if name_args.size != 2
          show_usage
          exit 1
        end

        if name_args.first.split('.').first == "prod"
          ui.error("Not Authorized to create alarms for prod. Exiting.\nThis incident will be reported")
          exit 1
        end

        config[:action] = 'cloud_watch'
        build_config(name_args)
        print_config

        alarm_config = []
        alarms = []

        #
        # Find the Servers first
        #
        if config[:hostname].count('%') == 1
          name_args[1] = config[:hostname].split('%').first + '*'
        else
          name_args[1] = config[:hostname]
        end

        servers = get_servers(name_args)
        exit 1 if servers.size == 0

        #
        # Print Server Info
        #
        print_cluster_info(servers)

        #
        # Print Config
        #
        print_table(config[:cw_alarm] , 'CloudWatch Alarms Config') if config[:verbosity] > 0
        exit 1 if config[:only_config]

        #
        # Create Alarms
        #
        Parallel.map(servers.length.times.to_a, :in_threads => servers.size) do |num|
          begin
            puts "\nSetting CloudWatch Alarm for #{servers[num].tags['fqdn']}"

            alarm_config[num] = {
              'AlarmName' =>  servers[num].tags['fqdn'] + "_ec2_shutdown_" + servers[num].id,
              'Dimensions' => [
                {
                  'Name' => 'InstanceId',
                  'Value' => servers[num].id
                }
              ]
            }
            alarm_config[num].merge!( config[:cw_alarm] )
            print_table(alarm_config[num], "CloudWatch Config #{servers[num].tags['fqdn']}")
            alarms[num] = cloudwatch.put_metric_alarm( alarm_config[num] )
          rescue Exception=>e
            puts e.backtrace.inspect unless config[:verbosity] < 1
            ui.warn("#{e.message}\nException while creating cloudwatch alarm for  #{servers[num].tags['fqdn']}")
          end
        end

        #
        # Done
        #
        print_messages
        print "#{ui.color("\nDone!\n\n", :bold)}"

      end

      def build_config(name_args)
        base_config(name_args) do 
          config[:hostname] = @yaml['instance']["#{config[:hosttype]}"]['hostname']
          config[:vpc], config[:subnet] = name_args[0].split('.')
        end

        #Check for CloudWatch alarms
        unless @yaml['instance']["#{config[:hosttype]}"]['cloudwatch'].nil?
          puts "\nBuilding CloudWatch Config"
          config[:cw_set_alarms] = true
          cw_metric = @yaml['instance']["#{config[:hosttype]}"]['cloudwatch']['metric'].split(' ')
          cw_operations = @yaml['instance']["#{config[:hosttype]}"]['cloudwatch']['operations'].split(' ')
          cw_period = @yaml['instance']["#{config[:hosttype]}"]['cloudwatch']['period'].split(' ')

          config[:cw_alarm] = {
            'Namespace'            => cw_metric.first,
            'MetricName'           => cw_metric.last,
            'Period'               => cw_period.first.to_i,
            'EvaluationPeriods'    => cw_period.last.to_i,
            'Statistic'            => cw_operations[0],
            'Threshold'            => cw_operations[2].to_i,
            'AlarmActions'         => ["arn:aws:automate:" + locate_config_value(:region) + ":ec2:stop"]
          }

          config[:cw_alarm]['ComparisonOperator'] = begin
            case cw_operations[1]
              when '<'
                'LessThanThreshold'
              when '>'
                'GreaterThanThreshold'
              when '<='
                'LessThanOrEqualToThreshold'
              when '>='
                'GreaterThanOrEqualToThreshold'
              else
                raise CloudwatchError.new("Cloudwatch Operation not recognized.")
            end
          end

        end
      end

    end
  end
end
