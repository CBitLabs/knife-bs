#
# Author:: Maciej Pasternacki (<maciej@pasternacki.net>)
# Copyright:: Copyright (c) 2010 Maciej Pasternacki
# License:: Apache License, Version 2.0
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# Modifications made by ops@bitsighttech.com

require 'chef/knife'

class Chef
  class Knife
    class BsDataBagFromYaml < Knife
      deps do
        require 'chef/knife/data_bag_from_file'
        Chef::Knife::DataBagFromFile.load_deps
        require 'yaml'
        require 'tempfile'
      end

      banner "knife bs data bag from yaml BAG NAME FILE (options)"

      def run
        databag_from_file = Chef::Knife::DataBagFromFile.new
        data_bag, name, item_path = name_args
        data = YAML::load_file(
          databag_from_file.loader.find_file("data_bags", data_bag, item_path))
        # Adds the id to atlas.yaml as specified on CLI
        data['id'] = name
        tmpf = Tempfile.new([data_bag, '.json'])
        tmpf.puts Chef::JSONCompat.to_json(data)
        tmpf.close
        databag_from_file.config = config
        databag_from_file.name_args = [ data_bag, tmpf.path ]
        databag_from_file.run
      end
    end
  end
end
