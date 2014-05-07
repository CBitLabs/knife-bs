# -*- coding: utf-8 -*-
require 'rubygems'
require 'chef/knife/bs_base'
require 'chef/knife/ec2_server_create'
require 'chef/knife/bs_server_create'
require 'parallel'
require 'fog'
require 'knife-bs/monkey_patches/hash'

class Chef
  class Knife
    class BsStackCreate < Knife
      include BsBase

      attr_accessor :configs
      attr_accessor :root_config

      def self.each_args
        @each_args ||= SubConfig.new({})
      end


      banner "
############################################################################
----------------------------------------------------------------------------
knife bs stack create VPC.SUBNET STACK (options)
----------------------------------------------------------------------------

Building upon the 'server create' command, this allows you to, in
parallel, spin up an entire stack.

For a hadoop cluster stack defined as:
stacks:
  ...
  hadoop-cluster:
    profiles:
      master:
      slave:
        count: 9
  ...
The command would be:
knife bs stack create ame1.dev hadoop-cluster \
  --each 'master: --ebs 200 --latest; slave: --ebs 1000 --latest'

Use semicolons to separate profile args (as they would be passed to
server create). Prefix the args with the profile name followed by a colon.
Be sure to put the entire argument set in quotes.

############################################################################
"
      parse_each = proc do |e|
        e.split(';').each do |profile|
          profile.strip!
          p_args = profile.split(':')
          BsStackCreate.each_args[p_args[0]] =
            (p_args[1..-1] * ':').split
          # For each profile name, save it* in the SubConfig
          # * --> the array of everything after the colon split by whitespace
        end
      end

      option :each_profile,
             :long => "--each CONFIG",
             :description => "Arguments you wish to pass to the server create"\
                             " method for each profile type.",
             :proc => parse_each

      option :dry_run,
             :long => '--mock',
             :description => "Don't really run, just use mock calls"

      option :bootstrap_version,
             :long => "--bootstrap-version VERSION",
             :description => "The version of Chef to install",
             :proc => Proc.new { |v| Chef::Config[:knife][:bootstrap_version] = v }

      ## TODO add optional delay in seconds between starting each
      ## profile in the cluster

      def run
        $stdout.sync = true

        if config[:dry_run]
          ui.msg(ui.color('Initiating dry run', :bold))
          Fog.mock!
          Fog::Mock.delay = 0
        end

        # configs will store each individual config for each instance
        # type defined in the stack
        @configs   = SubConfig.new({})

        # Need to replace config so that we can have multiple instances
        # running in parallel. Create a copy of the configuration
        @root_config = config.dup
        alias :old_config  :config
        alias :config :root_config

        # Now that we have the old config saved, we can use it to create
        # new 'config' variables in each scope
        build_config(name_args)
        stack = @bs.get_stack
        stack[:profiles] &&
          # stack.profiles.each do |p,info|
          Parallel.map(stack.profiles, in_threads:
                                         stack[:profiles].size) do |p,info|
          # For each profile, build the arguments, create an instance
          # of BsServerCreate, then run it
          inst = BsServerCreate.new(build_subconfig(p, info))
          inst.config = configs[p].hash.dup
          BsServerCreate.load_deps
          inst.parse_options(BsStackCreate.each_args[p])
          #inst.configure_chef
          inst.run#_with_pretty_exceptions
        end
      end

      def build_config(name_args)
        ## REVIEW this for --novpc?
        if name_args.size != 2
          show_usage
          exit 1
        end

        @root_name_args = name_args.dup
        name_args.reverse!
        # Get the stack from name_args
        config[:vpc], config[:subnet] = name_args.pop.split('.')
        config[:stack] = name_args.pop
        @bs = BsConfig.new(config)
        @bs.load_yaml
      end

      # Returns a name_args list
      def build_subconfig(profile, info)
        args = [@root_name_args[0],
                profile]#.concat(BsStackCreate.each_args[profile])
        conf = @root_config.dup
        if info
          # Any settings in the stack definition should be parsed here
          # For now just count
          conf[:number_of_nodes] = info[:count] if info[:count]
        else
          conf[:number_of_nodes] = 1
        end

        configs[profile] = conf
        args
      end
    end
  end
end
