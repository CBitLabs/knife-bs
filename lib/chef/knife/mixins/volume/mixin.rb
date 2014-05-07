require 'chef/knife/bs_mixin'
require 'chef/knife/bs_config'
require 'pry'

class VolumeMixin
  include ::Chef::Knife::BsMixin

  def initialize(bsconf, data)
    super(bsconf, 'volume', data, File.expand_path(File.dirname(__FILE__)))
  end

  def validate_ebs(bsconf)
    errs = []
    return errs unless @data[:ebs]
    devices = @data.ebs.select { |k,v| !v[:temp] }
    unless devices
      # Return no errors since there are no devices
      return errs
    end

    # flattens the list of volume lists in to one Array, then checks
    # if any of them are temp volumes.
    extra_temps = proc do |vollist|
      vollist.flatten.select {|vol| vol.delete_on_termination}.any?
    end

    duplicates = proc do |vollist|
      vollist.select {|volume_list| volume_list.size > 1 }.any?
    end

    bsconf.nodes.each do |fqdn|
      results = {
        :exist?      => false,
        :duplicates? => false,
        :temp?       => false
      }
      list_of_vols = [] # Array of Arrays
      devices.each do |dev,info|
        # add prefix if checking for temp volume
        tfqdn = fqdn
        tfqdn = "#{get_mount(dev)}-#{fqdn}" if info[:temp]
        # Append to list_of_vols the Array built by Array#select
        list_of_vols << bsconf.connection.volumes.select do |v|
          # volumes match if they're 'Name' and 'device' tags are equal
          tfqdn == v.tags['Name'] && dev == v.tags['device']
        end
        # reset fqdn back to normal if we changed it to look for temps.
        #fqdn = fqdn.gsub("#{mnt}-",'') if info[:temp]
      end

      # check that volumes exist
      results[:exist?] =
        devices.size <= bsconf.connection.volumes.all('tag-value'=>fqdn).size

      # check for duplicate volumes
      results[:duplicates?] = duplicates.call (list_of_vols)

      # check if any temp volumes hanging around
      results[:temp?]       = extra_temps.call (list_of_vols)

      # Make error messages
      node = fqdn.split('.').first

      errs << "[#{node}] Some/all EBS volumes in the YAML aren't in EC2" unless results[:exist?]
      errs << "[#{node}] There are duplicate EBS volumes in EC2!" if results[:duplicates?]
      errs << "[#{node}] Some temp volume(s) exist in EC2!" if results[:temp?]
    end
    errs
  end

  def get_ebs_raid_devs(raid_dev)
    @data.ebs.select do |_,info|
      info[:raid] && info.raid == raid_dev
    end
  end

  def get_temp_devices
    temps = []
    temps << @data.ephemeral.hash.keys if @data[:ephemeral]
    if @data[:ebs]
      temps << @data.ebs.each_with_object([]) do |o,arr|
        d, info = o; arr << d if info[:temp]
      end
    end
    temps.flatten
  end

  def get_format(device, type=:ebs)
    if @data[type] && @data[type][device]
      dev = @data[type][device]
      # puts "Device: #{device}\n"\
      #      "Type: #{type}\n"\
      #      "@data[type] => #{data[type].hash.inspect}"
      return dev[:format] || "ext4"
    end
  end

  def get_mount(device, type=:ebs)
    if @data[type] && @data[type][device]
      dev = @data[type][device]
      dev[:mount] ||
        (dev[:mount_detail][:dir] if dev[:mount_detail])
    end
  end

  def get_mounts(types=%w[ephemeral ebs raid bind])
    finder_by_type = proc do |volume_type|
      next unless @data.has_key? volume_type
      @data[volume_type].each_with_object [] do |o,arr|
        mnt = get_mount(o[1])
        arr << mnt if mnt
      end
    end

    types.map do |vol_type|
      finder_by_type.call(vol_type)
    end.compact.flatten
  end

  def update_rcd(ssh, filename, opts)
    update_rcd_cmd =
      ['sudo update-rc.d',
       filename,
       opts] * ' '
    ::Chef::Knife::BsMixin.run_command(ssh, update_rcd_cmd)
  end

  def service(ssh, srv, action, opts=[])
    service_cmd =
      ['sudo service',
       srv, action, *opts] * ' '
    ::Chef::Knife::BsMixin.run_command(ssh, service_cmd)
  end

  def volume_functions(server)
    action('install', server, 'bs-volumes')
  end

  def bs_ebs_functions(server)
    action('install', server, 'bs-ebs-functions')
  end

  def bs_ephemeral_functions(server)
    action('install', server, 'bs-ephemeral-functions')
  end

  def bs_swap_functions(server)
    action('install', server, 'bs-swap-functions')
  end

  def bs_bind_functions(server)
    action('install', server, 'bs-bind-functions')
  end

  def bs_volume_init(server)
    action('install', server, 'bs_volume_init') do |ssh, execonf|
      update_rcd(ssh, File.basename(execonf[:installed][server.id]),
                 'defaults 01')
      service(ssh, 'bs_volume_init', 'start')
    end
  end
end
