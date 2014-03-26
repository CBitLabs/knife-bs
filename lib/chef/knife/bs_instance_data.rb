require 'chef/knife'
require 'chef/knife/bs_base'
require 'chef/knife/ec2_instance_data'


class Chef
  class Knife
    class BsInstanceData < Knife::Ec2InstanceData

      include Knife::BsBase
      banner 'knife bs instance data (options)'

      option :edit,
        :short => "-e",
        :long => "--edit",
        :description => "Edit the instance data"

      option :run_list,
        :short => "-r RUN_LIST",
        :long => "--run-list RUN_LIST",
        :description => "Comma separated list of roles/recipes to apply",
        :proc => lambda { |o| o.split(/[\s,]+/) },
        :default => []

      def run

        super

      end
    end
  end
end
