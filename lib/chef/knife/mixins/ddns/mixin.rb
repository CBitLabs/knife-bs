require 'chef/knife/bs_mixin'

class DDNSMixin
  include ::Chef::Knife::BsMixin
  def initialize(bsconf, data)
    super(bsconf, 'ddns', data,
          File.expand_path(File.dirname(__FILE__)) )
  end
  
  def setup(server)
    action('run', server, 'ddns_setup')
  end
end
