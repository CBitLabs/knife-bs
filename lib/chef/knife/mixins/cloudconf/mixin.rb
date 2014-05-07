require 'chef/knife/bs_mixin'

class CloudConfMixin
  include ::Chef::Knife::BsMixin
  
  def initialize(bsconf, data)
    super(bsconf, 'cloudconf', data,
          File.expand_path(File.dirname(__FILE__)) )
  end
  
  def build
    cook('bs_cloud_conf', nil, true)
  end
end
