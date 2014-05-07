require 'chef/knife/bs_mixin'

class InstanceTagMixin
  include ::Chef::Knife::BsMixin

  def initialize(bsconf, data)
    super(bsconf, 'tag', data,
          File.expand_path(File.dirname(__FILE__)) )
  end

  def eval(bind)
    subst = proc do |value|
      bind.eval('"' + value + '"')
    end
    @data.each do |tag,val|
      @data[tag] = subst.call(val)
    end
  end
end
