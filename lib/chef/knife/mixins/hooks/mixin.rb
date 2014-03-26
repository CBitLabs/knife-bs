require 'chef/knife/bs_mixin'

class CloudHookMixin
  include ::Chef::Knife::BsMixin
  
  def initialize(user_data)
    super('hooks', user_data,
          File.expand_path(File.dirname(__FILE__)) )
  end

  def apply(server)
    action('run', server, 'cloud_hooks')
  end
end
