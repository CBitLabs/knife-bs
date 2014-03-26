require 'chef/knife/bs_mixin'

class DDNSMixin
  include ::Chef::Knife::BsMixin
  def initialize(user_data)
    super('ddns', user_data,
          File.expand_path(File.dirname(__FILE__)) )
  end
  
  def setup(server)
    action('run', server, 'ddns_setup')
  end
end
