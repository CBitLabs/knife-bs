require 'chef/knife'
require 'chef/knife/ec2_base'
require 'knife-bs/monkey_patches/ui'
require 'chef/knife/bs_mixin'
require 'chef/knife/bs_util'
# require 'pry'

class Chef
  class Knife

    ## Needs to load YAML before mixins, since mixins are
    ## initialized by the cascading mixin definitions

    ## Steps:
    ## 1. By the time we're here, command line arguments have been
    ##    parsed and are stored in #{config[]}.
    ## 2. Pass #{config} into #{bs_config} class (not necessary when
    ##    calling internal method
    ## 3. #{bs_config} will load up the #{yaml}
    ##   a) The YAML gets validated
    ##   b) Mixin data tree gets parsed
    ##   c) CLI params are merged in with yaml to create final
    ##      configuration.
    ## 4. Load up all of the mixins mentioned in the config, as well
    ##    as any default ones required for operation
    ## 5. Allow calling with a block for further configuration
    ##    inside here. This will be part of #{build_config} as it
    ##    stands. However #{base_config} will return as a result a new
    ##    configuration object which will be stored as #{@bsconf}

    class BsConfig < Chef::Config
      attr_accessor :yaml
      attr_accessor :mixins
      attr_accessor :ui
      extend ::Mixlib::Config
      include Hashit

      default (:yaml)         { Chef::Config[:knife][:yaml] }
      default (:start_time)   { Time.now.to_i }
      default (:client_key)   { Chef::Config[:client_key] }
      default (:ssh_key_name) { Chef::Config[:knife][:aws_ssh_key_id] }
      default :ssh_user,          'ubuntu'
      default :ssh_port,          22
      default :bootstrap_version, '11.8.0'
      default :distro,            'chef-full'
      default :flavor,            'm3.large'

      def self.required_mixins
        @@required_mixins
      end

      def self.qualified_mixins
        @@qualified_mixins
      end

      def self.ui
        @ui ||= Chef::Knife::UI.new(STDOUT, STDERR, STDIN, {})
      end

      # Expects that name_args have been pulled into config
      def initialize(config)
        @yaml = nil
        @ui = Chef::Knife::UI.new(STDOUT, STDERR, STDIN, {})
        defaults = BsConfig.save(true)
        super(defaults.merge! config)

        @@required_mixins  = Set.new
        @@qualified_mixins = Set.new

        usr_mixin_location = Chef::Config[:knife][:mixins]
        @@mixin_dirs  = `ls -d #{File.join(File.dirname(__FILE__), 'mixins', '/*')}`.chomp.split
        @@mixin_dirs |= `ls -d #{File.join(usr_mixin_location, '/*')}`.chomp.split
        # @user_mixins contains command line additions
        @mixins = SubConfig.new({})
      end

      def load_yaml
        begin
          ui.msg("Loading config from yaml : #{Chef::Config[:knife][:yaml]}")
          yaml = YAML.load_file(Chef::Config[:knife][:yaml])
          schema_file = File.expand_path(File.join(File.dirname(__FILE__), '../../bs-schema.yaml'))
          @mixin_validator = MixinValidator.new(YAML.load_file(schema_file))
          @mixin_validator.validate(yaml)
          @yaml = SubConfig.new(yaml)
        rescue Exception=>e
          ui.error("Failed to validate:\n#{e.message}")
          raise YamlError.new(e)
        end
      end

      def load_mixin(name, qualified=false)
        mdata = get_mixin_data(name)

        if mdata.nil?
          mdata = SubConfig.new({})
        elsif mdata.respond_to?('keys')
          mdata = SubConfig.new(mdata)
        end

        if qualified
          @mixins[name] = BsMixin::QualifiedMixin.new(name, mdata)
          ui.msg("Loaded qualified mixin '#{name}'")
        else
          @@mixin_dirs.each do |dir|
            mixin_name = File.basename(dir)
            next unless name == mixin_name
            # Any redefined user mixins override builtins
            ## Will not be able to load qualified mixins
            load "#{File.join(dir, 'mixin.rb')}"
            ui.msg("Loaded mixin '#{name}', (#{BsMixin.last_included.to_s})")
            # Loading the mixin includes BsMixin which keeps track of what
            # was included last
            @mixins[name] = BsMixin.last_included.new(mdata)
            ## TODO validate mixin_data
          end
        end
      end

      def load_mixins(list = nil)
        # Look for mixins in location specified by knife.rb config, 
        # as well as built in ones stored in this directory
        # Load up mixins from the command line as well as those
        # specified in the YAML file for whatever is being done.

        @@qualified_mixins.each { |m| load_mixin(m, true) }
        @@required_mixins.each { |m| load_mixin(m) }
        if has_key? :user_mixins
          @user_mixins.each { |m| load_mixin(m) }
        end
        if list
          list.each { |m| load_mixin(m) }
        end
      end

      ## -------------------------------------------------------
      ## Accessors
      ## -------------------------------------------------------
      def get_env(env)
        @yaml.env[env]
      end

      def get_region_vpc(vpc=nil)
        vpc ||= @vpc
        return nil unless vpc
        @yaml.regions.each do |reg, h|
          if h[:vpc]
            h.vpc.each do |_vpc, vpcdata|
              ## REVIEW lack of clean_key
              return reg, vpcdata if _vpc == vpc
            end
          end
        end
        nil
      end

      def get_subnet(vpc=nil, subnet=nil)
        subnet ||= @subnet
        vpc    ||= @vpc
        return nil unless [vpc, subnet].all?
        _, vpcdata = get_region_vpc(vpc)
        _, results = vpcdata.subnets.find do |snet, data|
          snet == subnet
        end
        return results
      end

      def get_stack(stack=nil)
        stack ||= @stack
        return nil unless stack
        @yaml.stacks[stack] if @yaml.stacks.respond_to? stack
      end

      def get_profile(profile=nil)
        profile  ||= @profile
        return nil unless profile
        @yaml.profiles[profile]# if @yaml.profiles.respond_to? profile
      end

      def get_all
        get_region_vpc << [get_subnet,
                           get_application_group,
                           get_application]
      end

      def get_mixin_data_for_level(base, mixin)
        if base &&
           base.respond_to?('mixin') &&
           base.mixin.respond_to?(mixin)
          base.mixin[mixin]
        else
          nil
        end
      end

      ## TODO iterate over all orgs
      def get_mixin_data_for_org(mixin, org=nil)
        base = @yaml.organizations.first[1]
        get_mixin_data_for_level(base, mixin)
      end

      def get_mixin_data_for_region(mixin, location=nil)
        rvpc = get_region_vpc
        base = rvpc ? @yaml.regions[rvpc[0]] : nil
        get_mixin_data_for_level(base, mixin)
      end

      def get_mixin_data_for_vpc(mixin, vpc=nil)
        rvpc = get_region_vpc(vpc)
        base = rvpc ? rvpc[1] : nil
        get_mixin_data_for_level(base, mixin)
      end

      def get_mixin_data_for_env(mixin, env=nil)
        base = get_env(env)
        get_mixin_data_for_level(base, mixin)
      end

      def get_mixin_data_for_subnet(mixin, vpc=nil, subnet=nil)
        base = get_subnet(vpc, subnet)
        get_mixin_data_for_level(base, mixin)
      end

      def get_mixin_data_for_stack(mixin, stack=nil)
        base = get_stack(stack)
        get_mixin_data_for_level(base, mixin)
      end

      def get_mixin_data_for_profile(mixin, profile=nil)
        base = get_profile(profile)
        get_mixin_data_for_level(base, mixin)
      end

      def get_mixin_data(mixin)
        merger = proc do |_,v1,v2|
          both_are = proc {|t| [v1,v2].all? {|v| v.is_a? (t)}}
          if both_are.call(Hash)
            v1.merge(v2,&merger)
          elsif both_are.call(SubConfig)
            SubConfig.new(v1.hash.merge(v2.hash, &merger))
          elsif both_are.call(Array)
            v1.concat(v2)
          else
            v2 ? v2 : v1
          end
        end

        mixin_data = nil
        [:get_mixin_data_for_org,
         :get_mixin_data_for_region,
         :get_mixin_data_for_vpc,
         :get_mixin_data_for_env,
         :get_mixin_data_for_subnet,
         :get_mixin_data_for_stack,
         :get_mixin_data_for_profile].each do |method|

          d = self.send(method, mixin)
          next unless d

          # binding.pry if mixin == 'ami'
          case d
          when String, Numeric
            mixin_data = d
          when Array
            mixin_data ?
              mixin_data.concat(d) :
              mixin_data = d
          when Hash
            mixin_data ?
              mixin_data.merge!(d, &merger) :
              mixin_data = d
          when SubConfig
            mixin_data ?
              mixin_data = SubConfig.new(mixin_data.hash.merge(d.hash, &merger)) :
              mixin_data = d
          end
        end
        ## TODO simple merge works until you have to clear the settings
        ## Defined above the level in question
        mixin_data
      end

      class MixinValidator < Kwalify::Validator
        def validate_hook(value, rule, path, errors)
          # Here we need to pass along the validation of each individual
          # mixin

          # If we stop using 'mixin': tags, then need to hook in here
          # and make correct modifications to the schema
          case rule.name
          when 'Mixin'
            BsConfig.required_mixins.add(File.basename(path))
          when 'QualifiedMixin'
            BsConfig.qualified_mixins.add(File.basename(path))
          end
        end
      end
    end
  end
end
