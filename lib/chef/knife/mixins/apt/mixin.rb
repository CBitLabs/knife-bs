require 'chef/knife/bs_mixin'

class AptMixin
  include ::Chef::Knife::BsMixin

  def initialize(bsconf, data)
    super(bsconf, 'apt', data,
          File.expand_path(File.dirname(__FILE__)) )
  end

  def cloud_config
    conf = ""
    if @data.has_key? :sources
      conf << "apt_sources:\n"
      @data.sources.each do |repo|
        conf << " - source: \"#{repo}\"\n"
      end
    end
    if @data.has_key? :packages
      conf << "packages:\n"
      @data.packages.each do |pkg|
        conf << " - #{pkg}\n"
      end
    end
    conf
  end
end
