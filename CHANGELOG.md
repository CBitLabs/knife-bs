# CHANGELOG for knife-bs

## 7.1.6:

* [Pasha] [FIX] Threading issue with bs.vars resolved

## 7.1.5:

* [Pasha] [FIX] Incorrect bs-ebs behavior when format is not
  defined. Assuming ext4 if none given in YAML. Tracking down bs.vars
  bug where all rs nodes came up with the same HOSTNAME and FQDN in
  /etc/bs.vars

## 7.1.4:

* [Pasha] [FIX] --match profile is now specified in the YAML instead of
  hardcoding "ms*"

## 7.1.3:

* [Pasha] [FIX] Local filesystem mounts/bindings

## 7.1.2:

* [Pasha] [FIX] Init script, ebs delete and server list fixes

## 7.1.1:

* [Pasha] [FIX] Merging Issa's changes to ebs delete

## 7.1.0:

* [Pasha] [OPEN-SOURCE] Modularization, generalization and cleanup

    - New YAML structure (`bs-atlas.yaml`)
        * Adds concept of `stacks` (cluster types) that can be declared
          at the top level. Stacks contain `profiles` (hadoop master,
          hadoop slaves, redis nodes, etc.)
        * Adds concept of environments which can exist across multiple
          EC2 `regions`, `VPC`s and `subnets`
        * Improves volume management by making volume declarations more
          general. Includes syntax for multiple RAID arrays of EBS
          volumes. Allows instance storage (`ephemeral`) to be RAID-ed
          as well.
        * Better integration with chef by allowing runlists to be
          defined at multiple levels and merged together
        * Improved, templated resource tagging using interpolated ruby
          strings within the root configuration context (`@bs`)
    - Mixins
        * Adds ability to inherit properties down the heirarchy and
          execute arbitrary code during phases (like before chef, after
          chef, later more granular events will be created) within commands
          like server create and ebs delete.
        * Currently an explicit `mixin` tag is required, will be merged
          with hierarchy attributes soon
        * Mixin packages may be created by users (WIP)
        * Configuration data may be provided at the following levels in
          the YAML:
            * `organization`
            * `environment`
            * `region`
            * `vpc`
            * `subnet`
            * `stack`
            * `profile`
        * Built-in mixins include:
            * `apt` - Sources and packages
            * `cloudconf` - User data on the instance
            * `ddns` - Dynamic DNS
            * `hooks` - Inlined bash commands
            * `ssh_keys` - Public keys for quick access during
              provisioning
            * `var` - Environment variables on the instance
            * `volume` - Block device and local binding
        * As well as simple data inheritance mixins (`qualified`) whose
          schema is defined along with the infrastructure
          (`bs-schema.yaml`)
            * `price` - AWS spot pricing
            * `az` - Availability zone in AWS
            * `tag` - Instance tags (**TODO**: any resource)
            * `chef` - Chef run lists and other settings
            * `ami` - AMI information for provisioning
            * `sg` - AWS security groups
            * `route-tbl` - AWS routing tables
        * Custom mixin file structure:
            * `MIXIN-NAME`
                * `mixin.rb` - Contains methods
    - Cleanup
        * Removed hardcoded and bitsight-specific defaults
        * Refactored limitations and assumed behavior
        * Removed `bs_kill_spare.rb`, moved functionality into
          `bs_server_delete.rb`
        * Automatic ephemeral drive configuration based on flavor
          information provided by
          [Fog](https://github.com/fog/fog). `Fog` version `1.20` is
          required, which is included in `knife-ec2` version
          [0.8.0](https://github.com/opscode/knife-ec2/commits/0.8.0)


## 7.0.1:

* [ISA] [OP-174] [FIX] Updates knife bs ebs delete to be more flexible,
  changes interface for ebs delete. 
  - Allows adding checks to deleting a specific volume id
  - Support deleting volumes for terminated servers
  - Adds devices option to delete volumes mounted to a specific point
  - Removes --ebs and --tmp options, as they hardcoded mount points

## 7.0.0:

* [Pasha] [CLEANUP] Pulled out bash commands into bash scripts

    - This has only been done for bs_server_create.rb. To do this for
      bs_ebs and bs_ami_create would require some refactoring

## 6.17.1

* [Pasha] [RP-2496] [FIX] simplified/optimized code for get_servers

## 6.17.0

* [Pasha] [RP-2496] [FEATURE] state filter no longer limited to 'running'

  - Allows you to list and delete stopped servers

## 6.16.1:

* [ISA] [FIX] Fixes check for /mnt/tmp, actually checking if it does not exist

## 6.16.0:

* [Isaac] [RP-2471] [FEATURE] Adds validation to `BsSubnetCreate`

  - Now checks are done to make sure a subnet of the same name or
    cidr block doesn't currently exist.

## 6.15.0:

* [Isaac] [RP-3006] [FEATURE] Adds ability to specify AMI prefix in YAML

## 6.14.1:

* [ISA] [RP-3006] [FIX] Shortens lognames if they are too long for most
  filesystems.

## 6.14.0:

* [Isaac] [RP-2543] [FEATURE] Adds ability to specify security group in
  YAML

* [Isaac] [CLEANUP] Moved `BsBase#create_instances` into
  `BsServerCreate`

  - Method was only being used there. Left
    `BsBase#create_spot_instancse` as is since it is used by
    `BsAmiCreate` and `BsSpotRequest` 

## 6.13.8:

* [Isaac] [PATCH] Increases Fog timeout to 10 minutes in
  `BsServerDelete`

## 6.13.7:

* [ISA] [FIX] Editing rc.local - Not formatting if already ext4 to avoid
  wiping on reboot

* [ISA] [FIX] Corrected the skipping of mounting so volumes still get
  labelled correectly

## 6.13.6:

* [ISA] [HACK] Unmounting /mnt if we are creating the /tmp

## 6.13.5:

* [ISA] [HACK] Forcing a request for ephemeral0 in bs_base block mapping
  request

* [ISA] [FIX] Correcting string replacement of hack, adding readlink to
  get rid of awk

* [ISA] [FIX] Updating list of AWS instances without ephemeral, removing
  the m3s and leaving just the micro

## 6.13.4:

* [ISA] [FIX] Hacked in TMP dir creation to `rc.local` if `/tmp` is
  symlinked

## 6.13.3:

* [Kevin] [FIX] Fixed bug with swapon

## 6.13.2:

* [ISA] [RP-2752] Adding `config[:yaml_tags]` to `create_server_tags`

## 6.13.1:

* [Isaac] [RP-2642] Adds script to `rc.local` to re-create swap file on
  reboot

## 6.13.0:

* [Isaac] [FIX] Updates `BsBase` to check for `vars` under VPC.

* [Isaac] [CLEANUP] Cleans up `BsServerCreate` by extracting monolithic
  run into several helper methods.

## 6.12.0:

* [Isaac] [FEATURE] Adds command `bs_subnet_list`

## 6.11.1:

* [Isaac] Updates how subnet ID is retreived in `bs_server_create`

* [Isaac] Updates how subnets are tagged in `bs_subnet_create`

## 6.11.0:

* [Isaac] Made `BsServerList` output prettier

* [Isaac] Updated gemspec to restrict `knife-ec2` version to 0.6.4

  - This is the last version with the method `bootstrap_for_node` in
    `Ec2ServerCreate`, afterwards was abstracted into
    `bootstrap_for_linux_node`, `bootstrap_for_windows_node`, and
    `bootstrap_common_params` when support for provisioning windows
    instances was added.

## 6.10.4:

* [Isaac] Setting `config[:bootstrap_version]` explicitly in more places
  to force version 11.8.0

## 6.10.3

* [Isaac] Increased default version of chef that is installed.

## 6.10.2:

* [Isaac] Fixed `BsSubnetCreate#create_subnet_tags` to properly tag
  subnets

## 6.10.1:

* [Isaac] Added options to specify route table and subnet IP via CLI

* [Isaac] Moved `create_subnet_tags` from `BsBase` to `BsSubnetCreate`

  - Was only used in there.

* [Isaac] Renamed `create_subnet_tags` to `tag_subnet`

* [Isaac] Refactored `BsSubnetCreate` to be better testable.

  - Expanded the help banner

  - Refactored `BsSubnetCreate#run` to use named helper methods

    * Configuration setup => `BsSubnetCreate#build_subnet_config`

      - Added helper methods for retrieving key-values from the YAML

    * Subnet creation => `BsSubnetCreate#create_subnet`

      - Subnet becomes an instance variable so other methods can access
        it when needed, i.e. in `BsSubnetCreate#associate_route_table`


## 6.10.0:

* [Isaac] Updated `BsBase#print_cluster_info`

  - Prints in alphabetic order

  - Downcases FQDNs of servers

  - Case statement now uses symbols instead of converting to strings

* [Isaac] Small change to `BsServerList` help string.

## 6.9.1:

* [Isaac] Updated Fog dependency to `~> 1.16`

  - Allows us to use it instead of boto to associate route tables.

## 6.9.0:

* [Isaac] Updated to allow the availability zone of a subnet to be
  specified in the YAML

## 6.8.6:

* [Kevin] Updated cloud-config file

## 6.8.5:

* [Isaac] [FIX] Updates `BsSubnetCreate` to properly retrieve values
  from the YAML.

## 6.8.4:

* [Isaac] [FIX] Updates `BsUtils::BsLogging` to properly escape logfile
  names

## 6.8.3:

* [Isaac] [TEMP-FIX] Updates `BsBase#cleanup_chef_objects`

  - Outputs all messages, output is not verbose enough to need silencing
    when things are running normally, and we want all the output we can
    get if things go wrong.

  - Updates number of tries to delete both clients and nodes to 10 times
    each.

## 6.8.2:

* [Isaac] [FIX] Fixes `BsServerCreate#validate!` to only validate nodes
  that define EBS volumes in the YAML.

## 6.8.1:

* [Isaac] [FIX] Fixes EBS validation when creating EBS volumes.

* [Isaac] [FIX] Fixes `BsBase#build_cloud_config` to only installs
  `mdadm` if creating RAID volumes.

* [Isaac] [FEATURE] Adds `knife-bs/monkey_patches/hash`

  - Adds a method for subtracting hashes, i.e.
    `a = {a: 'b', b: 'c', c: 'd', d: 'e'}`

    `b = {c: 'd', d: 'e'}`

    `a - b # => {a: 'b', b: 'c'}`

## 6.8.0:

* [Isaac] [FUNCTIONALITY] Adds better error output to
  `BsServerCreate#validate!`

  - Renamed `BsServerCreate#volumes_exist?` to `validate_ebs`

  - Added helper methods to check for duplicate EBS volumes as well as
    any temp volumes.

## 6.7.1:

* [Isaac] [FIX] Fixes the EBS-related validation methods in
  `BsServerCreate`

  - Methods now properly account for more than one server being
    created.

  - `BsServerCreate#volumes_exist?` now checks for temp volumes

## 6.7.0:

* [FUNCTIONALITY] Adds new file `knife-bs/errors` for knife-bs specific
  errors.

  - Updated `BsBase` to use new errors.

  - Updated error raising in `BsBase#get_ami_with_tag` to raise errors
    more gracefully.

## 6.6.2:

* [FUNCTIONALITY] Adds functionality to `BsServerCreate#validate!`

  - Checks if IP is in use

  - Validates the volumes defined in the YAML

  - Checks for duplicate volumes in EC2

  - `config[:fqdn]` is now set during `BsBase#build_config` for
    `server_create`

## 6.6.1:

* [FIX] Updates `BsBase#build_config` to check if IP is in use.

  - Adds initialization of `config[:subnet_id]` to inside the
    `server_create` part of the case statement inside
    `BsBase#build_config`

  - Updates `BsBase#create_instance` and
    `BsServerCreate#create_server_def` to reflect the new placement of
    the IP check.

## 6.6.0:

* [FIX] Fixes

  - Adds a new helper method `BsBase#ip_in_use?`

  - Updates `BsBase#create_instances` to use new helper method. The
    knife run will now quit if it detects that the IP address is already
    used.

  - Updates `BsServerCreate#create_server_def` to use new helper method
    as well

## 6.5.1:

* Updates `bs_server_list` to remove reference to uninitialized
  variable.

## 6.5:

* Updates `bs_server_list` to allow executing with just subnet.
* Updates banner formatting for `bs_server_list`

## 6.4.10:

* Adds knife-bs version to generated log headers.

## 6.4.9

* [FIX] Adds a check to determine whether or not we need to cleanup
  existing Chef clients and nodes.

* [FIX] Adds saving of nodes in the boostrap section of
  `bs_server_create`, otherwise setting the environment has no effect.

## 6.4.8

* [FIX] Adds a condition check which determines whether or not to add
  CloudWatch alarms to the instance being created. Spot instances do
  not receive them, others do.

## 6.4.7

* [FIX] Fixes 

  - Adds missing method `locate_config_value` to `Chef::Knife::BsBase`,
    the method is from `Chef::Knife::Ec2Base` which `bs_server_show` did
    not have access to as it inherited from `Chef::Knife`.

  - Updates `Chef::Knife::BsBase#print_nested_hash` to use the gem
    [awesome_print](https://github.com/michaeldv/awesome_print) instead
    of attempting to roll our own pretty printer.

## 6.4.6 and below

* Nobody recorded changes for me :'(
