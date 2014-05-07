require 'chef/knife/bs_mixin'

class VarMixin
  include ::Chef::Knife::BsMixin

  attr_accessor :sdata

  def initialize(bsconf, data)
    super(bsconf, 'var', data,
          File.expand_path(File.dirname(__FILE__)) )
    @sdata = {}
  end

  def add_vars(server)
    action('install', server, 'bs.vars')
    action('run',     server, 'install_bs_vars')
  end
end
