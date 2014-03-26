require 'chef/knife'
require 'chef/knife/bs_base'
require 'chef/knife/ec2_server_create'
require 'chef/knife/bootstrap'

class Chef
  class Knife
    class BsBootstrap < Knife::Ec2ServerCreate

      include Knife::BsBase

      deps do
        require 'fog'
        require 'readline'
        require 'chef/node'
        require 'chef/api_client'
        require 'chef/json_compat'
        require 'chef/knife/bootstrap'
        Chef::Knife::Bootstrap.load_deps
      end

      banner 'knife bs bootstrap (options)'

      option :distro,
             :short => "-d DISTRO",
             :long => "--distro DISTRO",
             :description => "Bootstrap a distro using a template; default is 'chef-full'",
             :proc => Proc.new { |d| Chef::Config[:knife][:distro] = d }

      option :chef_node_name,
             :short => "-N NAME",
             :long => "--node-name NAME",
             :description => "The Chef node name for your new node",
             :proc => Proc.new { |key| Chef::Config[:knife][:chef_node_name] = key }

      option :bootstrap_version,
             :long => "--bootstrap-version VERSION",
             :description => "The version of Chef to install",
             :proc => Proc.new { |v| Chef::Config[:knife][:bootstrap_version] = v }

      option :run_list,
             :short => "-r RUN_LIST",
             :long => "--run-list RUN_LIST",
             :description => "Comma separated list of roles/recipes to apply",
             :proc => lambda { |o| o.split(/[\s,]+/) }

      option :environment,
             :short => "-e ENVIRONMENT",
             :long => "--environment ENVIRONMENT",
             :description => "The Chef environment to place the node in",
             :default => "AME-OPS"

      option :subnet,
             :short => "-s SUBNET",
             :long => "--subnet SUBNET",
             :description => "The Subnet the server is located in",
             :proc => lambda { |o| o.split(/[\s,]+/) }

      option :ip,
             :short => '-f IP/FQDN',
             :long => '--fqdn IP/FQDN',
             :description => 'IP ADDRESS of the node to bootstrap'

      option :dont_preserve_run_list,
             :short => '-dp',
             :long => '--dont-preserve',
             :description => 'Don\'t preserve the already existing runlist',
             :default => false

      option :identity_file,
             :short => "-i IDENTITY_FILE",
             :long => "--identity-file IDENTITY_FILE",
             :description => "The SSH identity file used for authentication"



      def run
        $stdout.sync = true

        #
        # Build Config
        #
        bootstrap = build_bootstrap_config
        print_table(bootstrap.config, 'BOOTSTRAP CONFIG')
        #
        # If a client exists, then delete it
        #
        begin
          client = Chef::ApiClient.new
          client.name(config[:chef_node_name])
          client.destroy unless client.nil?
        rescue Exception=>e
          puts e.message unless config[:verbosity] < 1
          ui.warn('A client with the same name is registered with the chef server. Error deleting.')
        end

          print "\nWaiting for sshd on #{config[:ip]}"
            print('.') until tcp_test_ssh(config[:ip], config[:ssh_port]) {
              sleep @initial_sleep_delay ||= (vpc_mode? ? 30 : 10)
              puts("#{nodes[num]} ready")
          }
        #
        # Bootstrap it
        #
        begin
          bootstrap.run
          puts "#{ui.color("\n\nSuccessfully bootstrapped #{config[:chef_node_name]}!\n\n", :bold)}"
        rescue Exception=>e
          puts e.message
          ui.fatal('Error in bootstrapping.')
        end
      end


      ## TODO see if you can pull this out into bs_base. There might be 
      ## some common code you can eliminate
      def build_bootstrap_config
        bootstrap = Chef::Knife::Bootstrap.new

        if config[:ip]
          bootstrap.name_args = [config[:ip]]
          unless config[:chef_node_name]
            ui.error('Usage: knife bs bootstrap -i IP -N NODE-NAME')
            exit 1
          end

        else
          unless name_args.size == 2
            ui.error('Usage: knife bs bootstrap VPC.SUBNET HOSTNAME (options)')
            show_usage
            exit 1
          end
          config[:vpc] = name_args[0].split('.')[0]
          config[:subnet] = name_args[0].split('.')[1]
          config[:hosttype] = name_args[1]
          config[:yaml] ||= Chef::Config[:knife][:yaml]
          yaml = load_yaml
          puts yaml['instance']["#{config[:hosttype]}"] unless config[:verbosity] < 1
          config[:hostname] = yaml['instance']["#{config[:hosttype]}"]['hostname']

          filter = {}
          filter['tag-value'] = name_args[0] + ':' + config[:hostname]
          puts "Trying to locate server with tag-value : #{filter['tag-value']}"
          servers = connection.servers.all(filter)
          if servers.length == 0
            ui.fatal("Could not locate server with tag value: #{filter['tag-value']}.\nPlease check the server tags or enter and IP address to bootstrap.")
            exit 1
          end
          bootstrap.name_args = [ servers.first.private_ip_address ]

          config[:run_list] = []
          if yaml['instance']["#{config[:hosttype]}"]['run_list']
            puts 'Extracting runlist' unless config[:verbosity] < 1
            yaml['instance']["#{config[:hosttype]}"]['run_list'].each { |item|  config[:run_list] << item }
          end

          config[:chef_node_name] = "#{config[:hostname]}.#{config[:subnet]}" unless config[:chef_node_name]
          config[:environment] = yaml['vpc']["#{config[:vpc]}"]['lans']["#{config[:subnet]}"]['CHEF_ENV']

        end

        bootstrap.config[:run_list] = config[:run_list] || []
        bootstrap.config[:ssh_user] = config[:ssh_user] || 'ubuntu'
        bootstrap.config[:ssh_port] = config[:ssh_port] || 22
        bootstrap.config[:identity_file] = config[:identity_file] || "#{ENV['HOME']}/.chef/bitsight.pem"
        bootstrap.config[:chef_node_name] = config[:chef_node_name] || server.id
        bootstrap.config[:bootstrap_version] = config[:bootstrap_version] || '11.8.0'
        bootstrap.config[:distro] = locate_config_value(:distro) || "chef-full"
        bootstrap.config[:use_sudo] = true unless config[:ssh_user] == 'root'
        bootstrap.config[:environment] = config[:environment] || '_default'
        bootstrap.config[:host_key_verify] = false
        bootstrap
      end

    end
  end
end


