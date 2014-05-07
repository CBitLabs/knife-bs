require 'chef/knife'
require 'chef/knife/ec2_base'
require 'pry'

class Chef
  class Knife
    #  Hashit
    # Used to automatically provide setters and getters for any class
    # implementing a hash under the hood.
    #
    # Used in bs_config

    module Hashit
      include Enumerable
      attr_accessor :hash
      def initialize(val)
        begin
          @hash = {}
          @@bad_method_regex = Regexp.new(/[^a-zA-Z0-9!\=]/)
          unless val.respond_to?('[]') & hash.respond_to?('[]=')
            raise Exception.new('No getters or setters')
          end
          if val.respond_to?('each')
            val.each do |k, v|
              self[k] = v
            end
          elsif hash.respond_to?('keys')
            val.keys.each do |k|
              self[k] = v
            end
          else
            raise Exception.new('Cannot iterate over input')
          end
        rescue Exception=>e
          puts "Cannot convert given input (#{val.inspect}) to a hash (#{e.message})"
        end
      end

      def has_key?(k)
        @hash.has_key?(k.to_s)
      end

      def self.clean_key(k)
        k.to_s.gsub(@@bad_method_regex, '_')
      end

      def make_attr(k, v)
        cleaned_key = Hashit.clean_key(k)
        # Replace all invalid characters with underscore
        setv = v.is_a?(Hash) ? SubConfig.new(v) : v
        self.instance_variable_set("@#{cleaned_key}", setv)
        self.class.send(:define_method, cleaned_key,
                        proc {self.instance_variable_get("@#{cleaned_key}")})
        self.class.send(:define_method, "#{cleaned_key}=",
                        proc do |v|
                          setv = v.is_a?(Hash) ? SubConfig.new(v) : v
                          self.instance_variable_set("@#{cleaned_key}", setv)
                          @hash[k] = setv
                        end )
        # return cleaned key, and either a nested config or the scalar
        return cleaned_key, setv
      end

      # Iteration exposition
      def each &block
        @hash.each &block
      end

      def keys ; @hash.keys end

      def empty? ; @hash.empty? end

      def each_pair &block
        @hash.each_pair &block
      end

      def internal_get(k) ; @hash[k] end

      def internal_set(k, v)
        key, val = make_attr(k, v)
        @hash[k] = val
      end

      def [](config_option)
        internal_get(config_option.to_s)
      end

      def []=(config_option, value)
        internal_set(config_option.to_s, value)
      end

      def to_h
        res = {}
        @hash.each do |k,v|
          res[k] = (v.is_a?(Chef::Knife::SubConfig) ? v.to_h : v)
        end
        res
      end
    end

    class SubConfig
      extend ::Mixlib::Config
      include Hashit
    end
  end
end
